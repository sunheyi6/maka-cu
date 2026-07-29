import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit

// MARK: - Request parameters
//
// Every params struct is `Decodable` with no optional-bag shapes. §5 says why:
// optional `app` *and* optional `windowId` in one object is how a real-machine
// failure happened, where the contract said "app or window_id" while the harness
// required both. A tagged union cannot express that disagreement.

struct HostHelloParams: Decodable {
    let `protocol`: String
    let hostPid: Int32
    let imageDir: String
    let allowGlobalPointer: Bool
}

struct HostSessionBeginParams: Decodable {
    let session: String
    let captureScope: HostCaptureScope
}

struct HostSessionParams: Decodable {
    let session: String
}

enum HostTargetSelector: Decodable, Equatable {
    case app(String)
    case window(pid: pid_t, windowId: CGWindowID)

    private enum Key: String, CodingKey {
        case kind
        case app
        case pid
        case windowId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "app":
            self = .app(try container.decode(String.self, forKey: .app))
        case "window":
            self = .window(
                pid: try container.decode(Int32.self, forKey: .pid),
                windowId: CGWindowID(try container.decode(UInt32.self, forKey: .windowId))
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "target.kind"
            )
        }
    }
}

struct HostObserveParams: Decodable {
    let session: String
    let target: HostTargetSelector
    let includeImage: Bool?
    let maxElements: Int?
    let maxDepth: Int?
    let maxTextChars: Int?
}

struct HostPermissionsCheckParams: Decodable {
    let prompt: Bool?
}

struct HostAppsLaunchParams: Decodable {
    let session: String
    let app: String
    let waitForWindowMs: Int?
}

struct HostScreenCaptureParams: Decodable {
    let session: String
    let displayId: String
}

struct HostObserveAfter: Decodable {
    let includeImage: Bool
    let settle: HostSettleMode
}

struct HostDispatchElementParams: Decodable {
    let session: String
    let snapshotId: String
    let toolCallId: String
    let elementToken: String
    let expectElementDigest: String
    let strictness: HostStrictness?
    let occlusionPolicy: HostOcclusionPolicy?
    let action: HostElementAction
    let observeAfter: HostObserveAfter?
}

struct HostDispatchPointParams: Decodable {
    let session: String
    let snapshotId: String
    let toolCallId: String
    let expectWindowDigest: String
    let point: HostPoint
    let startPoint: HostPoint?
    let space: String
    let occlusionPolicy: HostOcclusionPolicy?
    let action: HostPointAction
    let observeAfter: HostObserveAfter?
}

struct HostDispatchKeyParams: Decodable {
    let session: String
    let snapshotId: String
    let toolCallId: String
    let focusToken: String
    let expectElementDigest: String
    let action: HostKeyAction
    let observeAfter: HostObserveAfter?
}

struct HostCancelParams: Decodable {
    let id: Int
}

extension HostElementAction: Decodable {
    private enum Key: String, CodingKey {
        case kind
        case button
        case count
        case value
        case text
        case action
        case direction
        case pages
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "click":
            let count = try container.decodeIfPresent(Int.self, forKey: .count) ?? 1
            guard (1...3).contains(count) else {
                throw DecodingError.dataCorruptedError(forKey: .count, in: container, debugDescription: "action.count")
            }
            self = .click(
                button: try container.decodeIfPresent(HostMouseButton.self, forKey: .button) ?? .left,
                count: count
            )
        case "set_value":
            self = .setValue(try container.decode(String.self, forKey: .value))
        case "select_text":
            self = .selectText(try container.decode(String.self, forKey: .text))
        case "secondary_action":
            self = .secondaryAction(try container.decode(HostElementActionName.self, forKey: .action))
        case "scroll":
            let pages = try container.decodeIfPresent(Double.self, forKey: .pages) ?? 1
            guard pages.isFinite, pages > 0 else {
                throw DecodingError.dataCorruptedError(forKey: .pages, in: container, debugDescription: "action.pages")
            }
            self = .scroll(direction: try container.decode(HostScrollDirection.self, forKey: .direction), pages: pages)
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "action.kind")
        }
    }
}

extension HostPointAction: Decodable {
    private enum Key: String, CodingKey {
        case kind
        case count
        case direction
        case pages
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        let count = try container.decodeIfPresent(Int.self, forKey: .count) ?? 1

        switch try container.decode(String.self, forKey: .kind) {
        case "move":
            self = .move
        case "left_click":
            self = .leftClick(count: count)
        case "right_click":
            self = .rightClick(count: count)
        case "middle_click":
            self = .middleClick(count: count)
        case "double_click":
            self = .leftClick(count: 2)
        case "triple_click":
            self = .leftClick(count: 3)
        case "mouse_down":
            self = .mouseDown
        case "mouse_up":
            self = .mouseUp
        case "drag":
            self = .drag
        case "scroll":
            let pages = try container.decodeIfPresent(Double.self, forKey: .pages) ?? 1
            guard pages.isFinite, pages > 0 else {
                throw DecodingError.dataCorruptedError(forKey: .pages, in: container, debugDescription: "action.pages")
            }
            self = .scroll(direction: try container.decode(HostScrollDirection.self, forKey: .direction), pages: pages)
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "action.kind")
        }
    }
}

extension HostKeyAction: Decodable {
    private enum Key: String, CodingKey {
        case kind
        case text
        case key
        case modifiers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "type":
            self = .type(try container.decode(String.self, forKey: .text))
        case "key":
            let name = try container.decode(String.self, forKey: .key)
            // §6.4 — a closed set of named keys plus single printable characters.
            // Anything else is `-32602` rather than a guess.
            guard hostKeyNameIsSupported(name) else {
                throw DecodingError.dataCorruptedError(forKey: .key, in: container, debugDescription: "action.key")
            }
            self = .key(
                name: name,
                modifiers: try container.decodeIfPresent([HostKeyModifier].self, forKey: .modifiers) ?? []
            )
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "action.kind")
        }
    }
}

/// The named keys the executor will accept, plus single printable characters.
public let hostNamedKeys: Set<String> = [
    "Return", "Enter", "Tab", "Space", "Escape", "Backspace", "Delete", "ForwardDelete",
    "Up", "Down", "Left", "Right", "Home", "End", "PageUp", "PageDown",
    "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12",
]

public func hostKeyNameIsSupported(_ name: String) -> Bool {
    if hostNamedKeys.contains(name) {
        return true
    }

    guard name.count == 1, let scalar = name.unicodeScalars.first else {
        return false
    }

    return scalar.value >= 0x20 && scalar.value < 0x7F
}

// MARK: - Response payloads

struct HostHelloResult: Encodable {
    let `protocol`: String
    let executor: Executor
    let pid: Int32
    let capabilities: HostCapabilities
    let limits: HostLimits

    struct Executor: Encodable {
        let name: String
        let version: String
        let commit: String
    }
}

struct HostSessionEndResult: Encodable {
    let released: HostSessionReleaseCounts
}

struct HostObserveResult: Encodable {
    let snapshot: HostSnapshotPayload
}

struct HostWindowListResult: Encodable {
    let windows: [Window]

    struct Window: Encodable {
        let pid: Int32
        let windowId: UInt32
        let appName: String
        let title: String?
        let bounds: HostRect
        let layer: Int
        let zIndex: Int
        let onScreen: Bool
        let displayId: String?
    }
}

struct HostAppsListResult: Encodable {
    let apps: [App]

    struct App: Encodable {
        let appId: String
        let pid: Int32
        let name: String
        let bundleId: String?
        let windowCount: Int
        let running: Bool
    }
}

struct HostPermissionsResult: Encodable {
    let accessibility: Bool
    let screenRecording: Bool
    let screenRecordingProbe: HostScreenRecordingProbe
}

struct HostAppsLaunchResult: Encodable {
    let pid: Int32
    let bundleId: String?
    let name: String
    let foregroundTaken: Bool
    let windows: [LaunchedWindow]
    let waited: Waited

    struct LaunchedWindow: Encodable {
        let windowId: UInt32
        let title: String?
    }

    struct Waited: Encodable {
        let ms: Int
        let reason: HostLaunchWaitReason
    }
}

struct HostSettleReport: Encodable {
    let waitedMs: Int
    let quiesced: Bool
    let reason: HostSettleReason
}

struct HostDispatchResult: Encodable {
    let toolCallId: String
    let outcome: HostDispatchOutcome
    let tier: HostDispatchTier
    let path: HostDispatchPath
    let effect: HostDispatchEffect
    let verification: HostVerification
    let settle: HostSettleReport
    let snapshot: HostSnapshotPayload?
    let postObservationError: HostDomainErrorCode?
}

struct HostScreenCaptureResult: Encodable {
    let image: HostImageReference
    let displayId: String
    let capturedAt: Int64
}

// MARK: - Server

/// The `maka.cu/1` executor. One reader, serial lanes, one response per request
/// id. Everything the host needs to reason about is a declared field; nothing is
/// inferred from a message string on either side.
public final class HostProtocolServer {
    let limits = HostLimits()
    private let capabilities = HostCapabilities()
    private let output: HostOutputWriter
    private let lanes = HostLaneScheduler()
    let cancellations = HostCancellationRegistry()

    private let stateLock = NSLock()
    private var handshakeComplete = false
    private var shuttingDown = false
    private var allowGlobalPointer = false
    private var imageStore: HostImageStore?
    private var registry: HostSnapshotRegistry?
    private var hostPidWatchdog: DispatchSourceTimer?

    /// Exit code the caller should use once `run()` returns. §2 requires `78`
    /// after a protocol mismatch, and the host must not retry that classification.
    public private(set) var exitStatus: Int32 = 0

    public init(output: HostOutputWriter = HostOutputWriter()) {
        self.output = output
    }

    // MARK: Run loop

    public func run() {
        installSignalHandling()

        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }

            handle(line: trimmed)

            if exitStatus == makaCuProtocolMismatchExitStatus {
                break
            }
        }

        _ = lanes.waitForCompletion(timeout: .now() + .milliseconds(limits.shutdownGraceMs))
        shutdownSessions()
    }

    /// Split from `run()` so the framing, handshake gate and routing can be
    /// exercised line by line in tests.
    public func handle(line: String) {
        let data = Data(line.utf8)

        guard let header = try? HostProtocolCodec.decoder.decode(HostRequestHeader.self, from: data) else {
            emit(id: nil, rpcError: HostRPCError(.parseError))
            return
        }

        guard header.jsonrpc == "2.0", let method = header.method else {
            emit(id: header.id, rpcError: HostRPCError(.invalidRequest))
            return
        }

        if method == "$/cancel" {
            if let params = try? HostProtocolCodec.decoder.decode(HostRequestEnvelope<HostCancelParams>.self, from: data).params {
                cancellations.cancel(id: params.id)
            }
            return
        }

        guard let id = header.id else {
            // A notification we do not implement. §1 gives notifications no id and
            // no response, so silence is the whole contract.
            return
        }

        stateLock.lock()
        let isShuttingDown = shuttingDown
        let isHandshakeComplete = handshakeComplete
        stateLock.unlock()

        if isShuttingDown {
            emit(id: id, rpcError: HostRPCError(.shuttingDown))
            return
        }

        if method == "host.hello" {
            // Handled on the reader thread rather than a lane: `host.hello` MUST
            // be the first message on the connection, so nothing can be in flight
            // beside it, and deferring it would let the next request race the
            // handshake gate and get a spurious `-32001`.
            handleHello(id: id, data: data)
            return
        }

        guard isHandshakeComplete else {
            emit(id: id, rpcError: HostRPCError(.handshakeRequired))
            return
        }

        route(method: method, id: id, data: data)
    }

    private func route(method: String, id: Int, data: Data) {
        switch method {
        case "session.begin":
            enqueueControl(id: id, data: data, handler: handleSessionBegin)
        case "session.end":
            enqueueControl(id: id, data: data, handler: handleSessionEnd)
        case "permissions.check":
            enqueueControl(id: id, data: data, handler: handlePermissionsCheck)
        case "apps.list":
            lanes.enqueue(.control) { [weak self] in
                self?.handleAppsList(id: id)
            }
        case "window.list":
            lanes.enqueue(.control) { [weak self] in
                self?.handleWindowList(id: id)
            }
        case "observe":
            enqueueTargetLane(id: id, data: data, handler: handleObserve)
        case "dispatch.element":
            enqueueTargetLane(id: id, data: data, handler: handleDispatchElement)
        case "dispatch.point":
            enqueueTargetLane(id: id, data: data, handler: handleDispatchPoint)
        case "dispatch.key":
            enqueueTargetLane(id: id, data: data, handler: handleDispatchKey)
        case "apps.launch":
            enqueueMisc(id: id, data: data, handler: handleAppsLaunch)
        case "screen.capture":
            enqueueMisc(id: id, data: data, handler: handleScreenCapture)
        case "capture.start", "capture.next", "capture.stop":
            // §10 — reserved. A *domain* result, never `-32601`, so feature
            // detection is a stable field read and the names can never be taken
            // by something else.
            lanes.enqueue(.control) { [weak self] in
                self?.emit(id: id, failure: HostDomainError(.notImplemented))
            }
        default:
            emit(id: id, rpcError: HostRPCError(.unknownMethod))
        }
    }

    // MARK: Lane helpers

    private func enqueueControl<Params: Decodable>(
        id: Int,
        data: Data,
        handler: @escaping (Int, Params) -> Void
    ) {
        guard let params = decode(Params.self, id: id, data: data) else {
            return
        }

        lanes.enqueue(.control) {
            handler(id, params)
        }
    }

    private func enqueueMisc<Params: Decodable>(
        id: Int,
        data: Data,
        handler: @escaping (Int, Params) -> Void
    ) {
        guard let params = decode(Params.self, id: id, data: data) else {
            return
        }

        lanes.enqueue(.misc) {
            handler(id, params)
        }
    }

    /// §9 — observes and dispatches against one window share a lane, so a
    /// dispatch can never overtake the observe that produced its snapshot.
    private func enqueueTargetLane<Params: Decodable>(
        id: Int,
        data: Data,
        handler: @escaping (Int, Params) -> Void
    ) {
        guard let params = decode(Params.self, id: id, data: data) else {
            return
        }

        lanes.enqueue(targetLane(for: params)) {
            handler(id, params)
        }
    }

    private func targetLane<Params>(for params: Params) -> HostLaneScheduler.Lane {
        if let observe = params as? HostObserveParams, case let .window(pid, windowId) = observe.target {
            return .target(pid: pid, windowId: windowId)
        }

        // A dispatch names a snapshot rather than a window, and the snapshot knows
        // which window it came from.
        let snapshotId: String?
        switch params {
        case let element as HostDispatchElementParams:
            snapshotId = element.snapshotId
        case let point as HostDispatchPointParams:
            snapshotId = point.snapshotId
        case let key as HostDispatchKeyParams:
            snapshotId = key.snapshotId
        default:
            snapshotId = nil
        }

        if let snapshotId,
           let session = sessionId(of: params),
           let snapshot = try? currentRegistry().resolve(session: session, snapshotId: snapshotId, now: hostNowMs()).get() {
            return .target(pid: snapshot.pid, windowId: snapshot.windowId)
        }

        return .misc
    }

    private func sessionId<Params>(of params: Params) -> String? {
        switch params {
        case let element as HostDispatchElementParams:
            return element.session
        case let point as HostDispatchPointParams:
            return point.session
        case let key as HostDispatchKeyParams:
            return key.session
        case let observe as HostObserveParams:
            return observe.session
        default:
            return nil
        }
    }

    private func decode<Params: Decodable>(_ type: Params.Type, id: Int, data: Data) -> Params? {
        do {
            guard let params = try HostProtocolCodec.decoder.decode(HostRequestEnvelope<Params>.self, from: data).params else {
                emit(id: id, rpcError: HostRPCError.invalidParams("params"))
                return nil
            }
            return params
        } catch let error as DecodingError {
            emit(id: id, rpcError: HostRPCError.invalidParams(hostDecodingField(error)))
            return nil
        } catch {
            emit(id: id, rpcError: HostRPCError(.internalError))
            return nil
        }
    }

    // MARK: Emission

    func emit(id: Int?, rpcError: HostRPCError) {
        guard let line = try? HostProtocolCodec.rpcErrorResponse(id: id, error: rpcError) else {
            return
        }
        output.write(line)
    }

    func emit(id: Int?, failure: HostDomainError, toolCallId: String? = nil) {
        guard let line = try? HostProtocolCodec.failureResponse(id: id, error: failure, toolCallId: toolCallId) else {
            return
        }
        output.write(line)
    }

    func emit<Payload: Encodable>(id: Int?, payload: Payload) {
        do {
            output.write(try HostProtocolCodec.okResponse(id: id, payload: payload))
        } catch {
            emit(id: id, rpcError: HostRPCError(.internalError))
        }
    }

    // MARK: Handshake

    private func handleHello(id: Int, data: Data) {
        guard let params = decode(HostHelloParams.self, id: id, data: data) else {
            return
        }

        guard params.protocol == makaCuProtocolVersion else {
            // §2 — fatal and loud. Flush, then exit 78 so the host classifies the
            // start as `service_mismatch` and does not retry.
            emit(
                id: id,
                rpcError: HostRPCError(.protocolVersionMismatch, supportedProtocols: [makaCuProtocolVersion])
            )
            exitStatus = makaCuProtocolMismatchExitStatus
            return
        }

        let store = HostImageStore(
            directory: URL(fileURLWithPath: params.imageDir, isDirectory: true),
            budgetBytes: limits.imageDirBudgetBytes
        )

        do {
            try store.verifyWritable()
        } catch let error as HostRPCError {
            emit(id: id, rpcError: error)
            return
        } catch {
            emit(id: id, rpcError: HostRPCError(.internalError))
            return
        }

        stateLock.lock()
        imageStore = store
        registry = HostSnapshotRegistry(limits: limits) { [weak store] path in
            store?.delete(path: path)
        }
        allowGlobalPointer = params.allowGlobalPointer
        handshakeComplete = true
        stateLock.unlock()

        startHostPidWatchdog(hostPid: params.hostPid)

        emit(
            id: id,
            payload: HostHelloResult(
                protocol: makaCuProtocolVersion,
                executor: HostHelloResult.Executor(
                    name: "maka-cu",
                    version: resolvedOpenComputerUseVersion(),
                    commit: openComputerUseBuildCommit()
                ),
                pid: ProcessInfo.processInfo.processIdentifier,
                capabilities: capabilities,
                limits: limits
            )
        )
    }

    /// §2 — macOS has no `PDEATHSIG`. Without this poll an orphaned executor
    /// holding Accessibility survives a host crash.
    private func startHostPidWatchdog(hostPid: pid_t) {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "maka-cu.host-watchdog"))
        timer.schedule(deadline: .now() + .seconds(2), repeating: .seconds(2))
        timer.setEventHandler { [weak self] in
            guard kill(hostPid, 0) != 0, errno == ESRCH else {
                return
            }

            self?.shutdownSessions()
            exit(0)
        }
        timer.resume()
        hostPidWatchdog = timer
    }

    private func installSignalHandling() {
        // §11 — stop reading new requests, let in-flight work finish inside the
        // grace period, end every session, exit 0. The host SIGKILLs after that.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: DispatchQueue(label: "maka-cu.sigterm"))
        source.setEventHandler { [weak self] in
            guard let self else {
                return
            }

            self.stateLock.lock()
            self.shuttingDown = true
            self.stateLock.unlock()

            _ = self.lanes.waitForCompletion(timeout: .now() + .milliseconds(self.limits.shutdownGraceMs))
            self.shutdownSessions()
            exit(0)
        }
        source.resume()
        sigtermSource = source
    }

    private var sigtermSource: DispatchSourceSignal?

    private func shutdownSessions() {
        stateLock.lock()
        let registry = self.registry
        stateLock.unlock()

        guard let registry else {
            return
        }

        for session in registry.liveSessionIds() {
            registry.endSession(session)
        }
    }

    func currentRegistry() -> HostSnapshotRegistry {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let registry else {
            preconditionFailure("registry is only reachable after a completed handshake")
        }
        return registry
    }

    func currentImageStore() -> HostImageStore {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let imageStore else {
            preconditionFailure("image store is only reachable after a completed handshake")
        }
        return imageStore
    }

    func globalPointerAllowed() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return allowGlobalPointer
    }

    // MARK: Sessions

    private func handleSessionBegin(id: Int, params: HostSessionBeginParams) {
        do {
            try currentRegistry().beginSession(params.session, captureScope: params.captureScope)
            emit(id: id, payload: HostEmptyPayload())
        } catch let error as HostRPCError {
            emit(id: id, rpcError: error)
        } catch {
            emit(id: id, rpcError: HostRPCError(.internalError))
        }
    }

    private func handleSessionEnd(id: Int, params: HostSessionParams) {
        // §3 also calls for removing any executor-drawn cursor. This executor
        // draws none: the host protocol runs without an AppKit run loop, and Maka
        // draws its own agent cursor precisely because a driver-drawn one outlived
        // the run that drew it. Reaching into `SoftwareCursorOverlay` from a lane
        // would deadlock on `DispatchQueue.main.sync` against a main thread parked
        // in `readLine`, so `released.streams` and the cursor are both nothing to
        // release rather than something we quietly skip.
        let released = currentRegistry().endSession(params.session)
        emit(id: id, payload: HostSessionEndResult(released: released))
    }

    // MARK: Reads

    private func handlePermissionsCheck(id: Int, params: HostPermissionsCheckParams) {
        // §5 — `prompt: false` MUST NOT raise a TCC dialog. The host calls this at
        // every action start because a user can revoke at any time, and a prompt
        // there would be a dialog storm.
        let diagnostics = PermissionDiagnostics.current()
        if params.prompt == true, !diagnostics.accessibilityTrusted {
            PermissionSupport.requestAccessibilityPrompt()
        }

        // The host currently prefers a live ScreenCaptureKit probe over the cached
        // boolean and has to guess which it got. This says.
        var probe = HostScreenRecordingProbe.notProbed
        if diagnostics.screenCaptureGranted {
            let probed = (try? BlockingAsyncBridge.run(timeout: 2) {
                try await SCShareableContent.current.displays.isEmpty == false
            }) ?? false
            probe = probed ? .captureSucceeded : .captureFailed
        }

        emit(
            id: id,
            payload: HostPermissionsResult(
                accessibility: diagnostics.accessibilityTrusted,
                screenRecording: diagnostics.screenCaptureGranted,
                screenRecordingProbe: probe
            )
        )
    }

    private func handleWindowList(id: Int) {
        let windows = HostWindowInventory.onScreenWindows().map {
            HostWindowListResult.Window(
                pid: $0.pid,
                windowId: $0.windowId,
                appName: $0.appName,
                title: $0.title,
                bounds: HostRect($0.bounds),
                layer: $0.layer,
                zIndex: $0.zIndex,
                onScreen: $0.onScreen,
                displayId: $0.displayId
            )
        }

        emit(id: id, payload: HostWindowListResult(windows: windows))
    }

    private func handleAppsList(id: Int) {
        let windows = HostWindowInventory.onScreenWindows()
        let apps = AppDiscovery.runningApps().map { app in
            HostAppsListResult.App(
                // §5 — bundle id where one exists, otherwise `pid:<n>`. The
                // host's existing fallback, moved to the side that knows.
                appId: app.bundleIdentifier ?? "pid:\(app.pid)",
                pid: app.pid,
                name: app.name,
                bundleId: app.bundleIdentifier,
                windowCount: windows.filter { $0.pid == app.pid && $0.layer == 0 }.count,
                running: !app.runningApplication.isTerminated
            )
        }

        emit(id: id, payload: HostAppsListResult(apps: apps))
    }
}
