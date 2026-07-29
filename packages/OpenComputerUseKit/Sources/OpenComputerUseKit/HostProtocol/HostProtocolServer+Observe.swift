import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public func hostNowMs() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1000)
}

/// Names the offending field for `-32602` without leaking a decoder's prose.
func hostDecodingField(_ error: DecodingError) -> String {
    switch error {
    case .keyNotFound(let key, _):
        return key.stringValue
    case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
        if !context.debugDescription.isEmpty, context.codingPath.isEmpty {
            return context.debugDescription
        }
        return context.codingPath.last?.stringValue ?? "params"
    @unknown default:
        return "params"
    }
}

// MARK: - Observation and dispatch

extension HostProtocolServer {
    // MARK: observe

    func handleObserve(id: Int, params: HostObserveParams) {
        guard requireSession(id: id, session: params.session) else {
            return
        }

        if let bound = validateObserveBounds(id: id, params: params) {
            emit(id: id, rpcError: bound)
            return
        }

        switch buildSnapshot(
            session: params.session,
            target: params.target,
            includeImage: params.includeImage ?? true,
            maxElements: params.maxElements ?? limits.maxElements,
            maxDepth: params.maxDepth ?? limits.maxDepth,
            maxTextChars: params.maxTextChars ?? limits.maxTextChars
        ) {
        case .success(let snapshot):
            currentRegistry().register(snapshot)
            emit(id: id, payload: HostObserveResult(snapshot: snapshot.payload))
        case .failure(let error):
            emit(id: id, failure: error)
        }
    }

    /// §5 — a value above the limit is `-32602`, not a silent clamp. Clamping is
    /// how a host ends up believing it asked for a bound the executor ignored.
    private func validateObserveBounds(id: Int, params: HostObserveParams) -> HostRPCError? {
        if let maxElements = params.maxElements, maxElements < 1 || maxElements > limits.maxElements {
            return HostRPCError.invalidParams("maxElements")
        }
        if let maxDepth = params.maxDepth, maxDepth < 1 || maxDepth > limits.maxDepth {
            return HostRPCError.invalidParams("maxDepth")
        }
        if let maxTextChars = params.maxTextChars, maxTextChars < 1 || maxTextChars > limits.maxTextChars {
            return HostRPCError.invalidParams("maxTextChars")
        }
        return nil
    }

    func requireSession(id: Int, session: String) -> Bool {
        guard currentRegistry().isSessionLive(session) else {
            emit(id: id, rpcError: HostRPCError(.sessionUnknown))
            return false
        }
        return true
    }

    /// The one place a snapshot is produced. Both `observe` and every
    /// `observeAfter` go through it, so a post-dispatch frame is the same shape,
    /// under the same bounds, as one the host asked for directly.
    func buildSnapshot(
        session: String,
        target: HostTargetSelector,
        includeImage: Bool,
        maxElements: Int,
        maxDepth: Int,
        maxTextChars: Int
    ) -> Result<HostSnapshot, HostDomainError> {
        if hostScreenIsLocked() {
            return .failure(HostDomainError(.screenLocked))
        }

        let diagnostics = PermissionDiagnostics.current()
        guard diagnostics.accessibilityTrusted else {
            return .failure(HostDomainError(.permissionMissing, detail: .missingPermission(.accessibility)))
        }

        let windows = HostWindowInventory.onScreenWindows()
        let resolved: HostWindowInfo
        switch target {
        case .window(let pid, let windowId):
            guard let match = windows.first(where: { $0.pid == pid && $0.windowId == windowId }) else {
                return .failure(HostDomainError(.windowGone))
            }
            resolved = match
        case .app(let query):
            guard let app = try? AppDiscovery.resolve(query) else {
                return .failure(HostDomainError(.appNotFound))
            }
            // `{ "kind": "app" }` resolves to the app's frontmost usable window
            // and is ambiguous by design; `{ "kind": "window" }` is exact.
            guard let match = windows.first(where: { $0.pid == app.pid && $0.layer == 0 }) else {
                return .failure(HostDomainError(.windowGone))
            }
            resolved = match
        }

        guard let windowElement = HostAX.window(pid: resolved.pid, windowId: resolved.windowId, bounds: resolved.bounds) else {
            return .failure(HostDomainError(.windowGone))
        }

        guard let startTime = hostProcessStartTime(pid: resolved.pid) else {
            return .failure(HostDomainError(.processReplaced))
        }

        var image: HostImageReference?
        if includeImage {
            let scope = currentRegistry().captureScope(of: session) ?? .window
            switch HostCapture.captureWindow(windowId: resolved.windowId, scope: scope) {
            case .success(let captured):
                switch currentImageStore().writePNG(
                    captured,
                    namePrefix: "snap",
                    logicalWidth: resolved.bounds.width
                ) {
                case .success(let reference):
                    image = reference
                case .failure(let error):
                    return .failure(error)
                }
            case .failure(let error):
                return .failure(error)
            }
        }

        let snapshotId = currentRegistry().nextSnapshotId()
        let focusedElement = HostAX.focusedElement(pid: resolved.pid)
        let capturedAt = hostNowMs()

        let walk = { (elementBudget: Int) -> HostTreeWalkResult in
            hostWalkTree(
                root: HostAXNode(
                    element: windowElement,
                    windowBounds: resolved.bounds,
                    focusedElement: focusedElement
                ),
                pid: resolved.pid,
                processStartTime: startTime,
                tokenPrefix: snapshotId,
                bounds: HostTreeWalkBounds(
                    maxElements: elementBudget,
                    maxDepth: maxDepth,
                    maxTextChars: maxTextChars
                )
            )
        }

        let selectedText = focusedElement
            .flatMap(HostAX.selectedText)
            .map { text -> HostSelectedText in
                let truncated = hostTruncate(text, limit: maxTextChars)
                return HostSelectedText(text: truncated.text ?? "", truncated: truncated.wasTruncated)
            }

        let obscuring = HostWindowInventory.obscuringRects(above: resolved, in: windows).map(HostRect.init)
        let displays = HostWindowInventory.displays()

        let fitted = hostFitResponse(
            maxElements: maxElements,
            limitBytes: limits.maxResponseBytes
        ) { budget -> (payload: (HostSnapshotPayload, HostTreeWalkResult), encoded: Data) in
            let result = walk(budget)
            let windowDigest = hostWindowDigest(
                elementDigests: result.elements.map(\.digest),
                bounds: resolved.bounds,
                title: resolved.title
            )

            let payload = HostSnapshotPayload(
                snapshotId: snapshotId,
                capturedAt: capturedAt,
                target: HostWindowTarget(
                    pid: resolved.pid,
                    windowId: resolved.windowId,
                    bundleId: NSRunningApplication(processIdentifier: resolved.pid)?.bundleIdentifier,
                    appName: resolved.appName,
                    title: resolved.title,
                    bounds: HostRect(resolved.bounds),
                    layer: resolved.layer,
                    zIndex: resolved.zIndex,
                    displayId: resolved.displayId
                ),
                windowDigest: windowDigest,
                focusedElementToken: result.focusedToken,
                selectedText: selectedText,
                image: image,
                displays: displays,
                obscuringRects: obscuring,
                elements: result.elements,
                truncated: result.truncated
            )

            let encoded = (try? HostProtocolCodec.encoder.encode(payload)) ?? Data()
            return ((payload, result), encoded)
        }

        switch fitted {
        case .failure(let error):
            if let path = image?.path {
                currentImageStore().delete(path: path)
            }
            return .failure(error)
        case .success(let fit):
            let (payload, walkResult) = fit.payload
            return .success(
                HostSnapshot(
                    id: snapshotId,
                    session: session,
                    pid: resolved.pid,
                    windowId: resolved.windowId,
                    capturedAt: capturedAt,
                    windowDigest: payload.windowDigest,
                    payload: payload,
                    bindings: walkResult.bindings,
                    imagePath: image?.path
                )
            )
        }
    }

    // MARK: dispatch.element

    func handleDispatchElement(id: Int, params: HostDispatchElementParams) {
        guard requireSession(id: id, session: params.session) else {
            return
        }

        let registry = currentRegistry()
        let snapshot: HostSnapshot
        switch registry.resolve(session: params.session, snapshotId: params.snapshotId, now: hostNowMs()) {
        case .success(let resolved):
            snapshot = resolved
        case .failure(let error):
            emit(id: id, failure: error, toolCallId: params.toolCallId)
            return
        }

        guard let binding = snapshot.binding(for: params.elementToken),
              binding.digest == params.expectElementDigest
        else {
            // Tokens are snapshot-scoped, and the echoed digest catches a host
            // that mixed up two elements from two snapshots — which the
            // executor's own record cannot see by construction.
            emit(id: id, failure: HostDomainError(.elementUnknown), toolCallId: params.toolCallId)
            return
        }

        if cancellations.isCancelledBeforeDispatch(id: id) {
            emit(id: id, failure: HostDomainError(.aborted), toolCallId: params.toolCallId)
            return
        }

        let windows = HostWindowInventory.onScreenWindows()
        guard let window = windows.first(where: { $0.pid == snapshot.pid && $0.windowId == snapshot.windowId }) else {
            emit(id: id, failure: HostDomainError(.windowGone), toolCallId: params.toolCallId)
            return
        }

        let probe = HostAXBindingProbe(windowBounds: window.bounds)
        if let failure = hostVerifyBinding(binding, probe: probe) {
            emit(id: id, failure: failure, toolCallId: params.toolCallId)
            return
        }

        // §6.1 `strictness: "window"` — the only defence against recycled row
        // views, at the cost of refusing on any change anywhere in the window.
        if params.strictness == .window {
            let current = recomputeWindowDigest(snapshot: snapshot, window: window, probe: probe)
            guard current == snapshot.windowDigest else {
                emit(id: id, failure: HostDomainError(.windowChanged), toolCallId: params.toolCallId)
                return
            }
        }

        if let frame = binding.observed.frame?.cgRect {
            let center = CGPoint(
                x: window.bounds.minX + frame.midX,
                y: window.bounds.minY + frame.midY
            )
            let obscuring = windows
                .filter { $0.layer == 0 && $0.zIndex > window.zIndex && $0.windowId != window.windowId }
                .filter { !HostWindowInventory.isFullScreenDockSurface($0) }
                .map { (pid: $0.pid, rect: $0.bounds) }

            if hostIsOccluded(
                policy: params.occlusionPolicy ?? .sameApp,
                targetPid: snapshot.pid,
                targetPoint: center,
                obscuringWindows: obscuring
            ) {
                emit(id: id, failure: HostDomainError(.windowOccluded), toolCallId: params.toolCallId)
                return
            }
        }

        guard binding.observed.enabled else {
            emit(id: id, failure: HostDomainError(.elementDisabled), toolCallId: params.toolCallId)
            return
        }

        guard let element = binding.element else {
            emit(id: id, failure: HostDomainError(.elementReleased), toolCallId: params.toolCallId)
            return
        }

        let settleMode = params.observeAfter?.settle ?? HostSettleMode.none
        cancellations.markDispatched(id: id)
        let performed = performElementAction(
            params.action,
            on: element,
            binding: binding,
            settle: settleMode
        )

        // §4.1 — a refused dispatch does not spend its snapshot; the host may fix
        // the argument and retry against the same frame.
        if performed.outcome == .refused, let failure = performed.failure {
            emit(id: id, failure: failure, toolCallId: params.toolCallId)
            return
        }

        // `outcome_unknown` does spend it, because we cannot prove the action did
        // not land.
        if performed.outcome == .unknown, let failure = performed.failure {
            currentRegistry().spend(snapshot)
            emit(id: id, failure: failure, toolCallId: params.toolCallId)
            return
        }

        finishDispatch(
            id: id,
            toolCallId: params.toolCallId,
            snapshot: snapshot,
            outcome: performed.outcome,
            path: performed.path,
            verificationIsTreeDelta: performed.verdict.verification.method == .treeDelta,
            fallbackVerdict: performed.verdict,
            settleMode: settleMode,
            observeAfter: params.observeAfter,
            window: window
        )
    }

    /// Recomputes the window digest from the snapshot's own bindings, so the
    /// comparison is over the same element set the host was shown.
    private func recomputeWindowDigest(
        snapshot: HostSnapshot,
        window: HostWindowInfo,
        probe: HostAXBindingProbe
    ) -> String {
        let digests = snapshot.payload.elements.compactMap { observed -> String? in
            guard let binding = snapshot.binding(for: observed.token) else {
                return nil
            }
            guard let current = probe.currentDigestInput(binding) else {
                return nil
            }
            return hostElementDigest(current)
        }

        return hostWindowDigest(elementDigests: digests, bounds: window.bounds, title: window.title)
    }

    private struct PerformedAction {
        let outcome: HostDispatchOutcome
        let path: HostDispatchPath
        let tier: HostDispatchTier
        let verdict: HostEffectVerdict
        let failure: HostDomainError?
    }

    private func performElementAction(
        _ action: HostElementAction,
        on element: AXUIElement,
        binding: HostElementBinding,
        settle: HostSettleMode
    ) -> PerformedAction {
        switch action {
        case .click(_, let count):
            guard let required = action.requiredElementAction else {
                // A middle click has no semantic equivalent: no AX action means
                // "the middle button". The host is told, rather than being given
                // a coordinate click it did not ask for.
                return refused(.elementNotActionable)
            }
            return performAXAction(required, on: element, binding: binding, repeatCount: count, settle: settle)

        case .secondaryAction(let name):
            // §6.5 — `secondary_action` gets `action_result` only. There is
            // nothing generic to read back.
            return performAXAction(name, on: element, binding: binding, repeatCount: 1, settle: .none)

        case .scroll(let direction, let pages):
            let name: HostElementActionName
            switch direction {
            case .up:
                name = .scrollUp
            case .down:
                name = .scrollDown
            case .left:
                name = .scrollLeft
            case .right:
                name = .scrollRight
            }

            // A whole number of pages is the only thing an AX scroll action can
            // express. Falling back to a wheel event here would silently change
            // the declared path, which §6.3 forbids.
            guard pages.rounded() == pages else {
                return refused(.unsupportedAction)
            }

            return performAXAction(name, on: element, binding: binding, repeatCount: Int(pages), settle: settle)

        case .setValue(let value):
            guard HostAX.isSettable(element, kAXValueAttribute) else {
                return refused(.elementNotActionable)
            }

            let previous = HostAX.stringLikeValue(element, kAXValueAttribute)
            let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString)
            guard result == .success else {
                return refused(.dispatchRefused, path: .axAttribute)
            }

            let readback = HostAX.stringLikeValue(element, kAXValueAttribute)
            return PerformedAction(
                outcome: .ok,
                path: .axAttribute,
                tier: .ax,
                verdict: hostEffectFromValueReadback(requested: value, previous: previous, readback: readback),
                failure: nil
            )

        case .selectText(let text):
            guard let value = HostAX.stringLikeValue(element, kAXValueAttribute),
                  let range = value.range(of: text)
            else {
                return refused(.elementNotActionable)
            }

            var cfRange = CFRange(
                location: value.distance(from: value.startIndex, to: range.lowerBound),
                length: text.count
            )
            guard let axRange = AXValueCreate(.cfRange, &cfRange) else {
                return refused(.dispatchRefused, path: .axAttribute)
            }

            let result = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange)
            guard result == .success else {
                return refused(.dispatchRefused, path: .axAttribute)
            }

            return PerformedAction(
                outcome: .ok,
                path: .axAttribute,
                tier: .ax,
                verdict: hostEffectFromSelectionReadback(
                    requested: text,
                    readback: HostAX.selectedText(element)
                ),
                failure: nil
            )
        }
    }

    private func performAXAction(
        _ name: HostElementActionName,
        on element: AXUIElement,
        binding: HostElementBinding,
        repeatCount: Int,
        settle: HostSettleMode
    ) -> PerformedAction {
        guard binding.observed.actions.contains(name) else {
            return refused(.elementNotActionable)
        }

        for _ in 0..<max(repeatCount, 1) {
            let result = AXUIElementPerformAction(element, name.rawAXAction as CFString)
            switch result {
            case .success:
                continue
            case .invalidUIElement:
                return refused(.elementReleased)
            case .cannotComplete:
                // The app accepted neither the message nor a refusal. We cannot
                // prove the action did not land, and §4.1 spends the frame for
                // exactly this case.
                return PerformedAction(
                    outcome: .unknown,
                    path: .axAction,
                    tier: .ax,
                    verdict: hostEffectFromActionResult(),
                    failure: HostDomainError(.outcomeUnknown)
                )
            default:
                return refused(.dispatchRefused, path: .axAction)
            }
        }

        // §6.5 — a bare `AXUIElementPerformAction` returning `.success` is not
        // confirmation. The tree delta, when settling was asked for, is.
        return PerformedAction(
            outcome: .ok,
            path: .axAction,
            tier: .ax,
            verdict: settle == .quiesce
                ? HostEffectVerdict(
                    effect: .unverifiable,
                    verification: HostVerification(method: .treeDelta, observedChange: false)
                )
                : hostEffectFromActionResult(),
            failure: nil
        )
    }

    private func refused(_ code: HostDomainErrorCode, path: HostDispatchPath = .none) -> PerformedAction {
        PerformedAction(
            outcome: .refused,
            path: path,
            tier: path.tier ?? .ax,
            verdict: HostEffectVerdict(
                effect: .unverifiable,
                verification: HostVerification(method: .none, observedChange: false)
            ),
            failure: HostDomainError(code)
        )
    }

    /// Common tail for all three dispatch methods: spend the frame the request
    /// quoted, settle, re-observe, and answer with one result carrying all four
    /// of `outcome`, `tier`, `path` and `effect`.
    func finishDispatch(
        id: Int,
        toolCallId: String,
        snapshot: HostSnapshot,
        outcome: HostDispatchOutcome,
        path: HostDispatchPath,
        verificationIsTreeDelta: Bool,
        fallbackVerdict: HostEffectVerdict,
        settleMode: HostSettleMode,
        observeAfter: HostObserveAfter?,
        window: HostWindowInfo
    ) {
        let digestBefore = snapshot.windowDigest
        currentRegistry().spend(snapshot)

        var settleReport = HostSettleReport(waitedMs: 0, quiesced: false, reason: .notRequested)
        var digestAfter: String?

        if settleMode == .quiesce {
            let settled = quiesce(snapshot: snapshot, window: window)
            settleReport = settled.report
            digestAfter = settled.digest
        }

        let verdict = verificationIsTreeDelta
            ? hostEffectFromTreeDelta(settle: settleMode, digestBefore: digestBefore, digestAfter: digestAfter)
            : fallbackVerdict

        var post: HostSnapshotPayload?
        var postError: HostDomainErrorCode?

        if let observeAfter {
            switch buildSnapshot(
                session: snapshot.session,
                target: .window(pid: snapshot.pid, windowId: snapshot.windowId),
                includeImage: observeAfter.includeImage,
                maxElements: limits.maxElements,
                maxDepth: limits.maxDepth,
                maxTextChars: limits.maxTextChars
            ) {
            case .success(let fresh):
                currentRegistry().register(fresh)
                post = fresh.payload
            case .failure(let error):
                // §6.1 — the action happened and must be reported even though the
                // frame after it could not be.
                postError = error.code
            }
        }

        emit(
            id: id,
            payload: HostDispatchResult(
                toolCallId: toolCallId,
                outcome: outcome,
                tier: path.tier ?? .ax,
                path: path,
                effect: verdict.effect,
                verification: verdict.verification,
                settle: settleReport,
                snapshot: post,
                postObservationError: postError
            )
        )
    }

    /// §6.1 — polls the AX tree without an image until two consecutive window
    /// digests match, or `limits.settleCeilingMs` elapses. The executor owns
    /// settling because it can watch the tree without a round trip.
    private func quiesce(
        snapshot: HostSnapshot,
        window: HostWindowInfo
    ) -> (report: HostSettleReport, digest: String?) {
        let started = Date()
        let probe = HostAXBindingProbe(windowBounds: window.bounds)
        var previous: String?

        while Date().timeIntervalSince(started) * 1000 < Double(limits.settleCeilingMs) {
            let current = recomputeWindowDigest(snapshot: snapshot, window: window, probe: probe)
            if current == previous {
                return (
                    HostSettleReport(
                        waitedMs: Int(Date().timeIntervalSince(started) * 1000),
                        quiesced: true,
                        reason: .quiesced
                    ),
                    current
                )
            }

            previous = current
            Thread.sleep(forTimeInterval: 0.05)
        }

        return (
            HostSettleReport(
                waitedMs: limits.settleCeilingMs,
                quiesced: false,
                reason: .ceiling
            ),
            previous
        )
    }
}

// MARK: - Point, key, launch and capture

extension HostProtocolServer {
    func handleDispatchPoint(id: Int, params: HostDispatchPointParams) {
        guard requireSession(id: id, session: params.session) else {
            return
        }

        // §6.3 — `space` is required and single-valued. A required field with one
        // legal value is how a second space gets added later without either side
        // guessing which one it was handed.
        guard params.space == "image_px" else {
            emit(id: id, rpcError: HostRPCError.invalidParams("space"))
            return
        }

        let registry = currentRegistry()
        let snapshot: HostSnapshot
        switch registry.resolve(session: params.session, snapshotId: params.snapshotId, now: hostNowMs()) {
        case .success(let resolved):
            snapshot = resolved
        case .failure(let error):
            emit(id: id, failure: error, toolCallId: params.toolCallId)
            return
        }

        // A point has no element to anchor to, so the whole window is the anchor.
        guard params.expectWindowDigest == snapshot.windowDigest else {
            emit(id: id, failure: HostDomainError(.windowChanged), toolCallId: params.toolCallId)
            return
        }

        if cancellations.isCancelledBeforeDispatch(id: id) {
            emit(id: id, failure: HostDomainError(.aborted), toolCallId: params.toolCallId)
            return
        }

        let windows = HostWindowInventory.onScreenWindows()
        guard let window = windows.first(where: { $0.pid == snapshot.pid && $0.windowId == snapshot.windowId }) else {
            emit(id: id, failure: HostDomainError(.windowGone), toolCallId: params.toolCallId)
            return
        }

        // `image_px` is only meaningful against the image the quoted snapshot
        // carried, and its measured scale is the only conversion we trust.
        guard let scale = snapshot.payload.image?.scale, scale > 0 else {
            emit(id: id, failure: HostDomainError(.invalidPoint), toolCallId: params.toolCallId)
            return
        }

        let screenPoint = CGPoint(
            x: window.bounds.minX + params.point.x / scale,
            y: window.bounds.minY + params.point.y / scale
        )
        let screenStart = params.startPoint.map {
            CGPoint(
                x: window.bounds.minX + $0.x / scale,
                y: window.bounds.minY + $0.y / scale
            )
        }

        let path: HostDispatchPath
        switch hostPointDispatchPath(
            action: params.action,
            point: screenPoint,
            startPoint: screenStart,
            windowBounds: window.bounds,
            allowGlobalPointer: globalPointerAllowed()
        ) {
        case .success(let selected):
            path = selected
        case .failure(let error):
            emit(id: id, failure: error, toolCallId: params.toolCallId)
            return
        }

        let obscuring = windows
            .filter { $0.layer == 0 && $0.zIndex > window.zIndex && $0.windowId != window.windowId }
            .filter { !HostWindowInventory.isFullScreenDockSurface($0) }
            .map { (pid: $0.pid, rect: $0.bounds) }

        // §6.3 — the default is `any` here, not `same_app`. A pixel is a pixel:
        // anything on top of it owns it.
        if hostIsOccluded(
            policy: params.occlusionPolicy ?? .any,
            targetPid: snapshot.pid,
            targetPoint: screenPoint,
            obscuringWindows: obscuring
        ) {
            emit(id: id, failure: HostDomainError(.windowOccluded), toolCallId: params.toolCallId)
            return
        }

        let settleMode = params.observeAfter?.settle ?? HostSettleMode.none
        cancellations.markDispatched(id: id)

        do {
            try postPointEvent(
                params.action,
                at: screenPoint,
                from: screenStart,
                pid: snapshot.pid,
                path: path
            )
        } catch let error as HostDomainError {
            emit(id: id, failure: error, toolCallId: params.toolCallId)
            return
        } catch {
            emit(id: id, failure: HostDomainError(.dispatchRefused), toolCallId: params.toolCallId)
            return
        }

        finishDispatch(
            id: id,
            toolCallId: params.toolCallId,
            snapshot: snapshot,
            outcome: .ok,
            path: path,
            verificationIsTreeDelta: true,
            fallbackVerdict: hostEffectFromActionResult(),
            settleMode: settleMode,
            observeAfter: params.observeAfter,
            window: window
        )
    }

    private func postPointEvent(
        _ action: HostPointAction,
        at point: CGPoint,
        from start: CGPoint?,
        pid: pid_t,
        path: HostDispatchPath
    ) throws {
        // Only the pid-bound paths are reachable when `allowGlobalPointer` is
        // false, and `hostPointDispatchPath` has already refused anything else.
        switch action {
        case .move:
            try InputSimulation.moveGlobally(to: point)
        case .leftClick(let count):
            try postClick(at: point, button: .left, count: count, pid: pid, path: path)
        case .rightClick(let count):
            try postClick(at: point, button: .right, count: count, pid: pid, path: path)
        case .middleClick(let count):
            try postClick(at: point, button: .middle, count: count, pid: pid, path: path)
        case .mouseDown, .mouseUp:
            // A half click has no target-bound form that survives the executor's
            // own event source going away between the two halves.
            throw HostDomainError(.unsupportedAction)
        case .drag:
            guard let start else {
                throw HostDomainError(.invalidPoint)
            }
            if path == .cgEventGlobal {
                try InputSimulation.dragGlobally(from: start, to: point)
            } else {
                try InputSimulation.dragTargeted(from: start, to: point, pid: pid)
            }
        case .scroll(let direction, let pages):
            if path == .cgEventGlobal {
                try InputSimulation.scrollGlobally(at: point, direction: direction.rawValue, pages: pages)
            } else {
                try InputSimulation.scrollTargeted(at: point, direction: direction.rawValue, pages: pages, pid: pid)
            }
        }
    }

    private func postClick(
        at point: CGPoint,
        button: MouseButtonKind,
        count: Int,
        pid: pid_t,
        path: HostDispatchPath
    ) throws {
        if path == .cgEventGlobal {
            try InputSimulation.clickGlobally(at: point, button: button, clickCount: count)
        } else {
            try InputSimulation.clickTargeted(at: point, button: button, clickCount: count, pid: pid)
        }
    }

    // MARK: dispatch.key

    func handleDispatchKey(id: Int, params: HostDispatchKeyParams) {
        guard requireSession(id: id, session: params.session) else {
            return
        }

        let registry = currentRegistry()
        let snapshot: HostSnapshot
        switch registry.resolve(session: params.session, snapshotId: params.snapshotId, now: hostNowMs()) {
        case .success(let resolved):
            snapshot = resolved
        case .failure(let error):
            emit(id: id, failure: error, toolCallId: params.toolCallId)
            return
        }

        guard let binding = snapshot.binding(for: params.focusToken),
              binding.digest == params.expectElementDigest
        else {
            emit(id: id, failure: HostDomainError(.elementUnknown), toolCallId: params.toolCallId)
            return
        }

        if cancellations.isCancelledBeforeDispatch(id: id) {
            emit(id: id, failure: HostDomainError(.aborted), toolCallId: params.toolCallId)
            return
        }

        let windows = HostWindowInventory.onScreenWindows()
        guard let window = windows.first(where: { $0.pid == snapshot.pid && $0.windowId == snapshot.windowId }) else {
            emit(id: id, failure: HostDomainError(.windowGone), toolCallId: params.toolCallId)
            return
        }

        if let failure = hostVerifyBinding(binding, probe: HostAXBindingProbe(windowBounds: window.bounds)) {
            emit(id: id, failure: failure, toolCallId: params.toolCallId)
            return
        }

        // §6.4 — `focusToken` is required and verified. Typing into whatever
        // `focusedElement` has become since the snapshot is the same class of
        // defect as re-resolving an index.
        guard let element = binding.element,
              let focused = HostAX.focusedElement(pid: snapshot.pid),
              CFEqual(focused, element)
        else {
            emit(id: id, failure: HostDomainError(.focusChanged), toolCallId: params.toolCallId)
            return
        }

        let previousValue = HostAX.stringLikeValue(element, kAXValueAttribute)
        let settleMode = params.observeAfter?.settle ?? HostSettleMode.none
        cancellations.markDispatched(id: id)

        do {
            // Key events are posted to the target pid. The executor never
            // activates the application, raises its window, or changes the
            // frontmost app.
            switch params.action {
            case .type(let text):
                try InputSimulation.typeText(text, pid: snapshot.pid)
            case .key(let name, let modifiers):
                try InputSimulation.pressKey(
                    hostKeySpecification(name: name, modifiers: modifiers),
                    pid: snapshot.pid,
                    extraFlags: modifiers.contains(.fn) ? .maskSecondaryFn : []
                )
            }
        } catch {
            emit(id: id, failure: HostDomainError(.dispatchRefused), toolCallId: params.toolCallId)
            return
        }

        let readback = HostAX.stringLikeValue(element, kAXValueAttribute)
        let verdict: HostEffectVerdict
        if previousValue == nil, readback == nil {
            // Nothing to read back means nothing was checked, and §6.5 makes that
            // distinguishable from "checked and inconclusive".
            verdict = HostEffectVerdict(
                effect: .unverifiable,
                verification: HostVerification(method: .none, observedChange: false)
            )
        } else {
            verdict = HostEffectVerdict(
                effect: readback == previousValue ? .suspectedNoop : .confirmed,
                verification: HostVerification(method: .valueReadback, observedChange: readback != previousValue)
            )
        }

        finishDispatch(
            id: id,
            toolCallId: params.toolCallId,
            snapshot: snapshot,
            outcome: .ok,
            path: .cgEventPid,
            verificationIsTreeDelta: false,
            fallbackVerdict: verdict,
            settleMode: settleMode,
            observeAfter: params.observeAfter,
            window: window
        )
    }

    // MARK: apps.launch

    func handleAppsLaunch(id: Int, params: HostAppsLaunchParams) {
        guard requireSession(id: id, session: params.session) else {
            return
        }

        let frontmostBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier

        guard let app = try? AppDiscovery.resolve(params.app) else {
            emit(id: id, failure: HostDomainError(.appNotFound))
            return
        }

        let started = Date()
        var windows: [HostAppsLaunchResult.LaunchedWindow] = []
        var reason = HostLaunchWaitReason.notRequested

        // §5 — the executor MUST wait for a window rather than returning the empty
        // array it sees at launch time. Measured: launch returns in 1.3–3.2 s and
        // the window is mapped 2.3–4.5 s in, so the array is empty on every real
        // launch unless somebody waits.
        if let waitMs = params.waitForWindowMs, waitMs > 0 {
            reason = .timeout
            while Date().timeIntervalSince(started) * 1000 < Double(waitMs) {
                let found = HostWindowInventory.onScreenWindows()
                    .filter { $0.pid == app.pid && $0.layer == 0 }
                if !found.isEmpty {
                    windows = found.map {
                        HostAppsLaunchResult.LaunchedWindow(windowId: $0.windowId, title: $0.title)
                    }
                    reason = .windowAppeared
                    break
                }

                Thread.sleep(forTimeInterval: 0.1)
            }
        } else {
            windows = HostWindowInventory.onScreenWindows()
                .filter { $0.pid == app.pid && $0.layer == 0 }
                .map { HostAppsLaunchResult.LaunchedWindow(windowId: $0.windowId, title: $0.title) }
        }

        let frontmostAfter = NSWorkspace.shared.frontmostApplication?.processIdentifier

        emit(
            id: id,
            payload: HostAppsLaunchResult(
                pid: app.pid,
                bundleId: app.bundleIdentifier,
                name: app.name,
                // §5 — declared, not inferred. An absent boolean that means
                // "unknown" is a three-valued field pretending to be two, and a
                // launch that took the foreground is still reported as such.
                foregroundTaken: frontmostAfter == app.pid && frontmostBefore != app.pid,
                windows: windows,
                waited: HostAppsLaunchResult.Waited(
                    ms: Int(Date().timeIntervalSince(started) * 1000),
                    reason: reason
                )
            )
        )
    }

    // MARK: screen.capture

    func handleScreenCapture(id: Int, params: HostScreenCaptureParams) {
        guard requireSession(id: id, session: params.session) else {
            return
        }

        guard let displayId = UInt32(params.displayId) else {
            emit(id: id, rpcError: HostRPCError.invalidParams("displayId"))
            return
        }

        switch HostCapture.captureDisplay(displayId: CGDirectDisplayID(displayId)) {
        case .failure(let error):
            emit(id: id, failure: error)
        case .success(let image):
            let logicalWidth = CGDisplayBounds(CGDirectDisplayID(displayId)).width
            switch currentImageStore().writePNG(image, namePrefix: "cap", logicalWidth: logicalWidth) {
            case .failure(let error):
                emit(id: id, failure: error)
            case .success(let reference):
                emit(
                    id: id,
                    payload: HostScreenCaptureResult(
                        image: reference,
                        displayId: params.displayId,
                        capturedAt: hostNowMs()
                    )
                )
            }
        }
    }
}

/// Translates the closed wire key set onto the internal xdotool-flavoured
/// specification `KeyPressParser` already understands. The wire set is the
/// contract; this mapping is an implementation detail that may change with it.
func hostKeySpecification(name: String, modifiers: [HostKeyModifier]) -> String {
    let modifierTokens = modifiers.compactMap { modifier -> String? in
        switch modifier {
        case .command:
            return "cmd"
        case .shift:
            return "shift"
        case .option:
            return "option"
        case .control:
            return "control"
        case .fn:
            // `fn` has no modifier key code to hold down; it travels as an event
            // flag instead, applied by the caller.
            return nil
        }
    }

    let keyToken: String
    switch name {
    case "ForwardDelete":
        keyToken = "forwarddelete"
    case "PageUp":
        keyToken = "pageup"
    case "PageDown":
        keyToken = "pagedown"
    default:
        keyToken = name.lowercased()
    }

    return (modifierTokens + [keyToken]).joined(separator: "+")
}
