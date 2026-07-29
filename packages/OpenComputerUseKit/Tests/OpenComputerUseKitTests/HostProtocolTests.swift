import CoreGraphics
import Foundation
import XCTest
@testable import OpenComputerUseKit

/// Conformance vectors for `maka.cu/1` (§12). Each test here fails without the
/// rule it names; the rules that need a live desktop (real Accessibility
/// invalidation, real capture) are called out in the commit rather than faked.
final class HostProtocolTests: XCTestCase {
    // MARK: - Frame binding (§4)

    func testDispatchQuotingASpentSnapshotFailsWithSnapshotSpent() {
        let registry = makeRegistry()
        try? registry.beginSession("s1", captureScope: .window)
        let snapshot = makeSnapshot(registry: registry, session: "s1", windowId: 1)
        registry.register(snapshot)

        registry.spend(snapshot)

        let result = registry.resolve(session: "s1", snapshotId: snapshot.id, now: hostNowMs())
        XCTAssertEqual(failureCode(result), .snapshotSpent)
    }

    func testSupersessionIsScopedToTheWindowItObserved() {
        let registry = makeRegistry()
        try? registry.beginSession("s1", captureScope: .window)

        let windowA = makeSnapshot(registry: registry, session: "s1", windowId: 1)
        let windowB = makeSnapshot(registry: registry, session: "s1", windowId: 2)
        registry.register(windowA)
        registry.register(windowB)

        let laterA = makeSnapshot(registry: registry, session: "s1", windowId: 1)
        registry.register(laterA)

        XCTAssertEqual(
            failureCode(registry.resolve(session: "s1", snapshotId: windowA.id, now: hostNowMs())),
            .snapshotSuperseded
        )
        XCTAssertNotNil(try? registry.resolve(session: "s1", snapshotId: windowB.id, now: hostNowMs()).get())
        XCTAssertNotNil(try? registry.resolve(session: "s1", snapshotId: laterA.id, now: hostNowMs()).get())
    }

    func testSnapshotOlderThanItsTimeToLiveFailsWithSnapshotExpired() {
        let registry = makeRegistry()
        try? registry.beginSession("s1", captureScope: .window)
        let snapshot = makeSnapshot(registry: registry, session: "s1", windowId: 1, capturedAt: 0)
        registry.register(snapshot)

        let result = registry.resolve(session: "s1", snapshotId: snapshot.id, now: Int64(HostLimits().snapshotTtlMs))
        XCTAssertEqual(failureCode(result), .snapshotExpired)
    }

    func testOverBudgetSessionEvictsTheOldestSnapshotRatherThanForgettingIt() {
        let limits = HostLimits()
        let registry = makeRegistry()
        try? registry.beginSession("s1", captureScope: .window)

        var snapshots: [HostSnapshot] = []
        for index in 0...limits.snapshotsPerSession {
            let snapshot = makeSnapshot(registry: registry, session: "s1", windowId: CGWindowID(index + 1))
            registry.register(snapshot)
            snapshots.append(snapshot)
        }

        // The oldest must be distinguishable from one that never existed: a host
        // holding too many frames and a dead executor need different responses.
        XCTAssertEqual(
            failureCode(registry.resolve(session: "s1", snapshotId: snapshots[0].id, now: hostNowMs())),
            .snapshotEvicted
        )
        XCTAssertEqual(
            failureCode(registry.resolve(session: "s1", snapshotId: "snap_nonexistent", now: hostNowMs())),
            .snapshotUnknown
        )
    }

    func testRefusedDispatchLeavesTheSnapshotLiveAndOutcomeUnknownSpendsIt() {
        let registry = makeRegistry()
        try? registry.beginSession("s1", captureScope: .window)
        let snapshot = makeSnapshot(registry: registry, session: "s1", windowId: 1)
        registry.register(snapshot)

        // A refusal never reaches `spend`, so the host may fix the argument and
        // retry against the same frame.
        XCTAssertEqual(registry.snapshotState(session: "s1", snapshotId: snapshot.id), .live)

        registry.spend(snapshot)
        XCTAssertEqual(registry.snapshotState(session: "s1", snapshotId: snapshot.id), .spent)
    }

    func testSnapshotIdsFromTwoExecutorGenerationsNeverCollide() {
        let first = makeRegistry()
        let second = makeRegistry()

        XCTAssertNotEqual(first.processNonce, second.processNonce)
        XCTAssertNotEqual(first.nextSnapshotId(), second.nextSnapshotId())
        XCTAssertEqual(first.processNonce.count, 32, "the nonce must carry 128 bits")
    }

    func testEndSessionReleasesEverySnapshotAndImageItOwned() {
        var deleted: [String] = []
        let registry = HostSnapshotRegistry(limits: HostLimits(), processNonce: "nonce-a") { deleted.append($0) }
        try? registry.beginSession("s1", captureScope: .window)

        registry.register(makeSnapshot(registry: registry, session: "s1", windowId: 1, imagePath: "/tmp/a.png"))
        registry.register(makeSnapshot(registry: registry, session: "s1", windowId: 2, imagePath: "/tmp/b.png"))

        let released = registry.endSession("s1")
        XCTAssertEqual(released.snapshots, 2)
        XCTAssertEqual(released.images, 2)
        XCTAssertEqual(released.streams, 0)
        XCTAssertEqual(deleted.sorted(), ["/tmp/a.png", "/tmp/b.png"])
    }

    func testEndingAnUnknownSessionIsIdempotentRatherThanAnError() {
        let registry = makeRegistry()
        let released = registry.endSession("never-begun")
        XCTAssertEqual(released.snapshots, 0)
        XCTAssertEqual(released.images, 0)
    }

    func testSupersededSnapshotLosesItsImageFile() {
        var deleted: [String] = []
        let registry = HostSnapshotRegistry(limits: HostLimits(), processNonce: "nonce-b") { deleted.append($0) }
        try? registry.beginSession("s1", captureScope: .window)

        registry.register(makeSnapshot(registry: registry, session: "s1", windowId: 7, imagePath: "/tmp/old.png"))
        registry.register(makeSnapshot(registry: registry, session: "s1", windowId: 7, imagePath: "/tmp/new.png"))

        // §8 — the image's lifetime is the snapshot's lifetime, so a stale path
        // fails rather than handing back a previous frame's pixels.
        XCTAssertEqual(deleted, ["/tmp/old.png"])
    }

    func testBeginningALiveSessionIdIsRejectedRatherThanSilentlyReset() {
        let registry = makeRegistry()
        XCTAssertNoThrow(try registry.beginSession("s1", captureScope: .window))
        XCTAssertThrowsError(try registry.beginSession("s1", captureScope: .window)) { error in
            XCTAssertEqual((error as? HostRPCError)?.code, .invalidParams)
        }
    }

    // MARK: - Element identity (§4.3)

    func testTokensAreLookedUpByExactStringWithinTheirOwnSnapshot() {
        let registry = makeRegistry()
        try? registry.beginSession("s1", captureScope: .window)
        let first = makeSnapshot(registry: registry, session: "s1", windowId: 1)
        let second = makeSnapshot(registry: registry, session: "s1", windowId: 2)

        let tokenFromFirst = first.payload.elements[0].token
        XCTAssertNotNil(first.binding(for: tokenFromFirst))
        // A token minted for snapshot A must not resolve inside snapshot B, which
        // is what stops an index from surviving a tree rebuild.
        XCTAssertNil(second.binding(for: tokenFromFirst))
    }

    func testDigestCoversTheUntruncatedValueSoLateEditsStillInvalidate() {
        let long = String(repeating: "a", count: 600)
        let recorded = HostElementDigestInput(role: "AXTextField", untruncatedValue: long)
        let edited = HostElementDigestInput(role: "AXTextField", untruncatedValue: long + "b")

        XCTAssertNotEqual(hostElementDigest(recorded), hostElementDigest(edited))
        XCTAssertEqual(hostChangedDigestFields(recorded: recorded, current: edited), [.value])

        // The wire copy is capped, and the cap is reported rather than implied.
        let wire = hostTruncate(long + "b", limit: 500)
        XCTAssertTrue(wire.wasTruncated)
        XCTAssertEqual(wire.text?.count, 500)
    }

    func testChangedFieldsNameEveryDigestInputThatMoved() {
        let recorded = HostElementDigestInput(
            role: "AXButton",
            label: "Send",
            frameInWindow: CGRect(x: 0, y: 0, width: 10, height: 10)
        )
        let current = HostElementDigestInput(
            role: "AXButton",
            label: "Sending",
            frameInWindow: CGRect(x: 4, y: 0, width: 10, height: 10)
        )

        XCTAssertEqual(hostChangedDigestFields(recorded: recorded, current: current), [.label, .frame])
    }

    func testBindingVerificationDistinguishesReleasedReplacedAndChanged() {
        let binding = makeBinding(token: "el_x", digestInput: HostElementDigestInput(role: "AXButton", label: "Send"))

        var probe = FakeBindingProbe(digestInput: binding.digestInput)
        probe.alive = false
        XCTAssertEqual(hostVerifyBinding(binding, probe: probe)?.code, .elementReleased)

        probe = FakeBindingProbe(digestInput: binding.digestInput)
        probe.startTime = binding.processStartTime + 1
        XCTAssertEqual(hostVerifyBinding(binding, probe: probe)?.code, .processReplaced)

        probe = FakeBindingProbe(digestInput: HostElementDigestInput(role: "AXButton", label: "Sent"))
        let failure = hostVerifyBinding(binding, probe: probe)
        XCTAssertEqual(failure?.code, .elementChanged)
        XCTAssertEqual(failure?.detail, .changed([.label]))

        probe = FakeBindingProbe(digestInput: binding.digestInput)
        XCTAssertNil(hostVerifyBinding(binding, probe: probe))
    }

    func testWindowDigestChangesWhenAnUnrelatedElementChanges() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let before = hostWindowDigest(elementDigests: ["a", "b"], bounds: bounds, title: "Untitled")
        let after = hostWindowDigest(elementDigests: ["a", "c"], bounds: bounds, title: "Untitled")
        let reordered = hostWindowDigest(elementDigests: ["b", "a"], bounds: bounds, title: "Untitled")

        // `strictness: "window"` refuses on this difference; `strictness: "element"`
        // never consults it.
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(before, reordered, "the digest is over a sorted set, not an order")
    }

    // MARK: - Bounded observation (§5, §7.4)

    func testTreeOverTheElementBudgetDeclaresTruncationAndStillReturnsUsableTokens() {
        let root = FakeNode(role: "AXWindow", children: (0..<10).map { FakeNode(role: "AXButton\($0)") })

        let walk = hostWalkTree(
            root: root,
            pid: 42,
            processStartTime: 7,
            tokenPrefix: "snap_test",
            bounds: HostTreeWalkBounds(maxElements: 4, maxDepth: 64, maxTextChars: 500)
        )

        XCTAssertEqual(walk.elements.count, 4)
        XCTAssertTrue(walk.truncated.elements)
        XCTAssertFalse(walk.truncated.depth)
        XCTAssertEqual(Set(walk.elements.map(\.token)).count, 4)
        XCTAssertEqual(walk.bindings.count, 4)
    }

    func testTreeOverTheDepthBudgetDeclaresDepthTruncation() {
        let leaf = FakeNode(role: "AXStaticText")
        let middle = FakeNode(role: "AXGroup", children: [leaf])
        let root = FakeNode(role: "AXWindow", children: [middle])

        let walk = hostWalkTree(
            root: root,
            pid: 42,
            processStartTime: 7,
            tokenPrefix: "snap_test",
            bounds: HostTreeWalkBounds(maxElements: 100, maxDepth: 1, maxTextChars: 500)
        )

        XCTAssertEqual(walk.elements.count, 2)
        XCTAssertTrue(walk.truncated.depth)
    }

    func testElementTextTruncationIsReportedPerFieldAndNeverOmitted() {
        let root = FakeNode(role: "AXTextField", value: String(repeating: "x", count: 20))

        let walk = hostWalkTree(
            root: root,
            pid: 1,
            processStartTime: 1,
            tokenPrefix: "snap_test",
            bounds: HostTreeWalkBounds(maxElements: 10, maxDepth: 10, maxTextChars: 5)
        )

        XCTAssertEqual(walk.elements[0].truncated, [.value])
        XCTAssertEqual(walk.elements[0].value?.count, 5)

        let untouched = hostWalkTree(
            root: FakeNode(role: "AXButton"),
            pid: 1,
            processStartTime: 1,
            tokenPrefix: "snap_test",
            bounds: HostTreeWalkBounds(maxElements: 10, maxDepth: 10, maxTextChars: 5)
        )
        XCTAssertEqual(untouched.elements[0].truncated, [])
    }

    func testRawAXActionsAreNormalisedOntoTheClosedSet() {
        let root = FakeNode(role: "AXButton", rawActionNames: ["AXPress", "AXShowMenu", "AXSomethingPrivate"])

        let walk = hostWalkTree(
            root: root,
            pid: 1,
            processStartTime: 1,
            tokenPrefix: "snap_test",
            bounds: HostTreeWalkBounds(maxElements: 10, maxDepth: 10, maxTextChars: 500)
        )

        // The host never sees `AXPress`, and an action it could not name in the
        // closed set is an action it could never request.
        XCTAssertEqual(walk.elements[0].actions, [.press, .showMenu])
    }

    func testResponseBudgetHalvesTheElementBoundBeforeGivingUp() {
        var attempts: [Int] = []
        let result = hostFitResponse(maxElements: 1000, limitBytes: 10) { budget in
            attempts.append(budget)
            return (payload: budget, encoded: Data(repeating: 0, count: budget))
        }

        XCTAssertEqual(attempts, [1000, 500, 250, 125])
        XCTAssertEqual(failureCode(result), .responseTooLarge)

        let fits = hostFitResponse(maxElements: 8, limitBytes: 10) { budget in
            (payload: budget, encoded: Data(repeating: 0, count: budget))
        }
        XCTAssertEqual(try? fits.get().payload, 8)
    }

    // MARK: - Declared schema (§6.3, §6.5)

    func testTierAndPathPairingsOutsideTheTableAreInconsistent() {
        XCTAssertTrue(hostTierIsConsistent(tier: .ax, path: .axAction))
        XCTAssertTrue(hostTierIsConsistent(tier: .coordinateBackground, path: .cgEventPid))
        XCTAssertTrue(hostTierIsConsistent(tier: .coordinateBackground, path: .skylightPid))
        XCTAssertFalse(hostTierIsConsistent(tier: .ax, path: .cgEventPid))
        XCTAssertFalse(hostTierIsConsistent(tier: .coordinateBackground, path: .axAttribute))
        XCTAssertFalse(hostTierIsConsistent(tier: .semanticBackground, path: .axAction))
    }

    func testSetValueReadbackEqualToThePreviousValueReportsSuspectedNoop() {
        let noop = hostEffectFromValueReadback(requested: "hello", previous: "old", readback: "old")
        XCTAssertEqual(noop.effect, .suspectedNoop)
        XCTAssertEqual(noop.verification.method, .valueReadback)
        XCTAssertFalse(noop.verification.observedChange)

        let confirmed = hostEffectFromValueReadback(requested: "hello", previous: "old", readback: "hello")
        XCTAssertEqual(confirmed.effect, .confirmed)
        XCTAssertTrue(confirmed.verification.observedChange)

        let surprising = hostEffectFromValueReadback(requested: "hello", previous: "old", readback: "something else")
        XCTAssertEqual(surprising.effect, .unverifiable)
        XCTAssertEqual(surprising.verification.method, .valueReadback)
    }

    func testClickWithoutSettlingNeverClaimsConfirmationFromATreeDelta() {
        let unsettled = hostEffectFromTreeDelta(settle: .none, digestBefore: "a", digestAfter: "b")
        XCTAssertEqual(unsettled.effect, .unverifiable)
        XCTAssertNotEqual(unsettled.verification.method, .treeDelta)

        let settled = hostEffectFromTreeDelta(settle: .quiesce, digestBefore: "a", digestAfter: "b")
        XCTAssertEqual(settled.effect, .confirmed)
        XCTAssertEqual(settled.verification.method, .treeDelta)

        let quiet = hostEffectFromTreeDelta(settle: .quiesce, digestBefore: "a", digestAfter: "a")
        XCTAssertEqual(quiet.effect, .unverifiable)
        XCTAssertEqual(quiet.verification.method, .treeDelta)
    }

    func testABareActionResultIsNeverConfirmation() {
        let verdict = hostEffectFromActionResult()
        XCTAssertEqual(verdict.effect, .unverifiable)
        XCTAssertEqual(verdict.verification.method, .actionResult)
    }

    func testUnverifiableIsDistinguishableFromNeverChecked() {
        // §6.5 — `effect: unverifiable` with `method: "none"` means never checked;
        // with `method: "value_readback"` it means checked and inconclusive.
        let neverChecked = HostVerification(method: .none, observedChange: false)
        let inconclusive = hostEffectFromValueReadback(requested: "a", previous: "b", readback: nil).verification

        XCTAssertNotEqual(neverChecked.method, inconclusive.method)
    }

    // MARK: - Path selection (§6.3)

    func testTargetReachableOnlyByTheGlobalPathIsRefusedRatherThanWarped() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)

        let refusal = hostPointDispatchPath(
            action: .move,
            point: CGPoint(x: 10, y: 10),
            startPoint: nil,
            windowBounds: bounds,
            allowGlobalPointer: false
        )

        XCTAssertEqual(failureCode(refusal), .dispatchRefused)
        if case .failure(let error) = refusal {
            XCTAssertEqual(error.detail, .wouldRequirePath(.cgEventGlobal))
        } else {
            XCTFail("a pointer move has no target-bound form and must be refused")
        }

        // The same request is allowed only when the host said so in the handshake.
        XCTAssertEqual(
            try? hostPointDispatchPath(
                action: .move,
                point: CGPoint(x: 10, y: 10),
                startPoint: nil,
                windowBounds: bounds,
                allowGlobalPointer: true
            ).get(),
            .cgEventGlobal
        )
    }

    func testDragLeavingTheTargetWindowIsRefusedWithoutGlobalPointer() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)

        let refusal = hostPointDispatchPath(
            action: .drag,
            point: CGPoint(x: 50, y: 50),
            startPoint: CGPoint(x: 400, y: 400),
            windowBounds: bounds,
            allowGlobalPointer: false
        )
        XCTAssertEqual(failureCode(refusal), .dispatchRefused)

        let inside = hostPointDispatchPath(
            action: .drag,
            point: CGPoint(x: 50, y: 50),
            startPoint: CGPoint(x: 10, y: 10),
            windowBounds: bounds,
            allowGlobalPointer: false
        )
        XCTAssertEqual(try? inside.get(), .cgEventPid)
    }

    func testPointOutsideTheTargetWindowIsAnInvalidPointNotARefusal() {
        let result = hostPointDispatchPath(
            action: .leftClick(count: 1),
            point: CGPoint(x: 900, y: 900),
            startPoint: nil,
            windowBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            allowGlobalPointer: false
        )

        XCTAssertEqual(failureCode(result), .invalidPoint)
    }

    // MARK: - Occlusion (§6.2)

    func testSameAppOcclusionIgnoresForeignWindowsStackedAbove() {
        let point = CGPoint(x: 50, y: 50)
        let covering = CGRect(x: 0, y: 0, width: 100, height: 100)

        // A background app launched by `apps.launch` starts at the bottom of the
        // z-order; treating foreign windows as occlusion refused every semantic
        // click it would ever receive.
        XCTAssertFalse(
            hostIsOccluded(
                policy: .sameApp,
                targetPid: 10,
                targetPoint: point,
                obscuringWindows: [(pid: 99, rect: covering)]
            )
        )

        // A same-app sheet is different: the element underneath is not the thing
        // to act on, whatever the AX tree says.
        XCTAssertTrue(
            hostIsOccluded(
                policy: .sameApp,
                targetPid: 10,
                targetPoint: point,
                obscuringWindows: [(pid: 10, rect: covering)]
            )
        )

        XCTAssertTrue(
            hostIsOccluded(
                policy: .any,
                targetPid: 10,
                targetPoint: point,
                obscuringWindows: [(pid: 99, rect: covering)]
            )
        )

        XCTAssertFalse(
            hostIsOccluded(
                policy: .none,
                targetPid: 10,
                targetPoint: point,
                obscuringWindows: [(pid: 10, rect: covering)]
            )
        )
    }

    // MARK: - Cancellation (§7.2)

    func testCancelBeforeDispatchAppliesAndAfterDispatchIsIgnored() {
        let registry = HostCancellationRegistry()

        registry.cancel(id: 42)
        XCTAssertTrue(registry.isCancelledBeforeDispatch(id: 42))

        registry.markDispatched(id: 42)
        // An action already in flight cannot be un-fired, and reporting `aborted`
        // for one that landed is a lie the host would act on.
        XCTAssertFalse(registry.isCancelledBeforeDispatch(id: 42))

        registry.markDispatched(id: 7)
        registry.cancel(id: 7)
        XCTAssertFalse(registry.isCancelledBeforeDispatch(id: 7))
    }

    // MARK: - Wire shape

    func testDomainFailuresTravelAsResultsNotJSONRPCErrors() throws {
        let line = try HostProtocolCodec.failureResponse(
            id: 3,
            error: HostDomainError(.elementChanged, detail: .changed([.value, .frame])),
            toolCallId: "call_1"
        )
        let json = try jsonObject(line)

        XCTAssertNil(json["error"], "a domain failure is never a JSON-RPC error")
        let result = try XCTUnwrap(json["result"] as? [String: Any])
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertEqual(result["toolCallId"] as? String, "call_1")

        let error = try XCTUnwrap(result["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "element_changed")
        XCTAssertEqual(error["message"] as? String, HostDomainErrorCode.elementChanged.message)
        let detail = try XCTUnwrap(error["detail"] as? [String: Any])
        XCTAssertEqual(detail["changed"] as? [String], ["value", "frame"])
    }

    func testEveryDomainCodeCarriesAFixedSentenceWithNoApplicationContent() {
        for code in HostDomainErrorCode.allCases {
            XCTAssertFalse(code.message.isEmpty, "\(code.rawValue) has no fixed sentence")
            XCTAssertFalse(
                code.message.contains(code.rawValue),
                "\(code.rawValue) restates its own code instead of explaining it"
            )
        }
    }

    func testOkResultsCarryTheirFieldsBesideTheTag() throws {
        let line = try HostProtocolCodec.okResponse(
            id: 1,
            payload: HostSessionEndResult(
                released: HostSessionReleaseCounts(snapshots: 3, images: 3, streams: 0)
            )
        )
        let result = try XCTUnwrap(try jsonObject(line)["result"] as? [String: Any])

        XCTAssertEqual(result["ok"] as? Bool, true)
        let released = try XCTUnwrap(result["released"] as? [String: Any])
        XCTAssertEqual(released["snapshots"] as? Int, 3)
    }

    func testNoResponseEverCarriesABase64Image() throws {
        let reference = HostImageReference(
            path: "/tmp/images/snap_1.png",
            format: .png,
            widthPx: 2400,
            heightPx: 1600,
            byteLength: 743_210,
            sha256: "sha256:9d81",
            scale: 2.0
        )
        let line = try HostProtocolCodec.okResponse(
            id: 1,
            payload: HostScreenCaptureResult(image: reference, displayId: "69732928", capturedAt: 1)
        )
        let text = try XCTUnwrap(String(data: line, encoding: .utf8))

        XCTAssertTrue(text.contains("/tmp/images/snap_1.png"))
        XCTAssertFalse(text.contains("\"data\""))
        XCTAssertFalse(text.contains("base64"))
    }

    func testEachEncodedResponseIsExactlyOneLine() throws {
        let line = try HostProtocolCodec.okResponse(id: 1, payload: HostEmptyPayload())
        let text = try XCTUnwrap(String(data: line, encoding: .utf8))

        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertEqual(text.filter { $0 == "\n" }.count, 1)
    }

    // MARK: - Handshake and routing (§2, §10)

    func testAnyMethodBeforeHostHelloIsHandshakeRequired() throws {
        let harness = ServerHarness()
        harness.send(#"{"jsonrpc":"2.0","id":1,"method":"observe","params":{"session":"s","target":{"kind":"app","app":"Notes"}}}"#)

        let error = try XCTUnwrap(try harness.awaitResponse()["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32001)
        XCTAssertEqual(error["message"] as? String, "handshake_required")
    }

    func testUnknownProtocolVersionIsFatalAndNamesWhatIsSupported() throws {
        let harness = ServerHarness()
        harness.sendHello(protocolVersion: "maka.cu/2")

        let response = try harness.awaitResponse()
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32000)
        XCTAssertEqual(error["message"] as? String, "protocol_version_mismatch")
        let data = try XCTUnwrap(error["data"] as? [String: Any])
        XCTAssertEqual(data["supported"] as? [String], ["maka.cu/1"])

        // §2 — `EX_CONFIG`, so the host classifies the start as `service_mismatch`
        // and does not retry.
        XCTAssertEqual(harness.server.exitStatus, 78)
    }

    func testHandshakeAnswersWithEveryLimitTheHostWouldOtherwiseHardcode() throws {
        let harness = ServerHarness()
        harness.sendHello()

        let result = try XCTUnwrap(try harness.awaitResponse()["result"] as? [String: Any])
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["protocol"] as? String, "maka.cu/1")

        let limits = try XCTUnwrap(result["limits"] as? [String: Any])
        for key in [
            "snapshotsPerSession", "snapshotTtlMs", "maxElements", "maxDepth", "maxTextChars",
            "maxResponseBytes", "settleCeilingMs", "shutdownGraceMs", "imageDirBudgetBytes",
        ] {
            XCTAssertNotNil(limits[key], "\(key) must travel in the handshake")
        }

        let capabilities = try XCTUnwrap(result["capabilities"] as? [String: Any])
        XCTAssertEqual(capabilities["captureStream"] as? Bool, false)
    }

    func testHandshakeFailsWhenTheImageDirectoryIsNotWritable() throws {
        let harness = ServerHarness()
        harness.sendHello(imageDir: "/var/db/maka-cu-does-not-exist")

        let error = try XCTUnwrap(try harness.awaitResponse()["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
        XCTAssertEqual((error["data"] as? [String: Any])?["field"] as? String, "imageDir")
    }

    func testCaptureStreamMethodsAnswerNotImplementedAsADomainResult() throws {
        let harness = ServerHarness()
        harness.sendHello()
        _ = try harness.awaitResponse()

        for method in ["capture.start", "capture.next", "capture.stop"] {
            harness.send(#"{"jsonrpc":"2.0","id":9,"method":"\#(method)","params":{}}"#)
            let response = try harness.awaitResponse()

            XCTAssertNil(response["error"], "\(method) must not be -32601")
            let result = try XCTUnwrap(response["result"] as? [String: Any])
            XCTAssertEqual(result["ok"] as? Bool, false)
            XCTAssertEqual((result["error"] as? [String: Any])?["code"] as? String, "not_implemented")
        }
    }

    func testSessionEndAnswersWithItsReleaseCountsRatherThanHanging() throws {
        let harness = ServerHarness()
        harness.sendHello()
        _ = try harness.awaitResponse()

        harness.send(#"{"jsonrpc":"2.0","id":2,"method":"session.begin","params":{"session":"s1","captureScope":"window"}}"#)
        XCTAssertEqual((try harness.awaitResponse()["result"] as? [String: Any])?["ok"] as? Bool, true)

        // Teardown must answer. An earlier revision reached into the AppKit cursor
        // overlay from the session lane, which blocked on `DispatchQueue.main.sync`
        // against a main thread parked in `readLine` and never replied at all.
        harness.send(#"{"jsonrpc":"2.0","id":3,"method":"session.end","params":{"session":"s1"}}"#)
        let result = try XCTUnwrap(try harness.awaitResponse()["result"] as? [String: Any])
        let released = try XCTUnwrap(result["released"] as? [String: Any])
        XCTAssertEqual(released["snapshots"] as? Int, 0)
        XCTAssertEqual(released["images"] as? Int, 0)
        XCTAssertEqual(released["streams"] as? Int, 0)
    }

    func testBeginningTheSameSessionTwiceIsRejectedOverTheWire() throws {
        let harness = ServerHarness()
        harness.sendHello()
        _ = try harness.awaitResponse()

        harness.send(#"{"jsonrpc":"2.0","id":2,"method":"session.begin","params":{"session":"s1","captureScope":"window"}}"#)
        _ = try harness.awaitResponse()

        harness.send(#"{"jsonrpc":"2.0","id":3,"method":"session.begin","params":{"session":"s1","captureScope":"window"}}"#)
        let error = try XCTUnwrap(try harness.awaitResponse()["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
    }

    func testAnUnknownMethodIsAJSONRPCErrorRatherThanADomainResult() throws {
        let harness = ServerHarness()
        harness.sendHello()
        _ = try harness.awaitResponse()

        harness.send(#"{"jsonrpc":"2.0","id":5,"method":"observe.everything","params":{}}"#)
        let error = try XCTUnwrap(try harness.awaitResponse()["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32601)
    }

    func testAMethodNamingAnUnknownSessionIsSessionUnknown() throws {
        let harness = ServerHarness()
        harness.sendHello()
        _ = try harness.awaitResponse()

        harness.send(#"{"jsonrpc":"2.0","id":6,"method":"observe","params":{"session":"never-begun","target":{"kind":"app","app":"Notes"}}}"#)
        let error = try XCTUnwrap(try harness.awaitResponse()["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32002)
    }

    func testNonJSONInputIsAParseErrorRatherThanASilentDrop() throws {
        let harness = ServerHarness()
        harness.send("this is not json")

        let error = try XCTUnwrap(try harness.awaitResponse()["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32700)
    }

    func testObserveBoundsAboveTheLimitAreRejectedRatherThanClamped() throws {
        let harness = ServerHarness()
        harness.sendHello()
        _ = try harness.awaitResponse()

        harness.send(#"{"jsonrpc":"2.0","id":2,"method":"session.begin","params":{"session":"s1","captureScope":"window"}}"#)
        _ = try harness.awaitResponse()

        harness.send(#"{"jsonrpc":"2.0","id":3,"method":"observe","params":{"session":"s1","target":{"kind":"window","pid":1,"windowId":1},"maxElements":999999}}"#)
        let error = try XCTUnwrap(try harness.awaitResponse()["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
        XCTAssertEqual((error["data"] as? [String: Any])?["field"] as? String, "maxElements")
    }

    func testCancelNotificationProducesNoResponse() throws {
        let harness = ServerHarness()
        harness.send(#"{"jsonrpc":"2.0","method":"$/cancel","params":{"id":42}}"#)

        XCTAssertThrowsError(try harness.awaitResponse(timeout: 0.2))
    }

    // MARK: - Key vocabulary (§6.4)

    func testKeyNamesOutsideTheClosedSetAreRejected() {
        XCTAssertTrue(hostKeyNameIsSupported("Return"))
        XCTAssertTrue(hostKeyNameIsSupported("F12"))
        XCTAssertTrue(hostKeyNameIsSupported("a"))
        XCTAssertFalse(hostKeyNameIsSupported("super+shift+q"))
        XCTAssertFalse(hostKeyNameIsSupported("Eject"))
        XCTAssertFalse(hostKeyNameIsSupported(""))
    }

    func testKeySpecificationDropsFnBecauseItHasNoKeyCodeToHold() {
        XCTAssertEqual(hostKeySpecification(name: "Return", modifiers: [.command, .shift]), "cmd+shift+return")
        XCTAssertEqual(hostKeySpecification(name: "Left", modifiers: [.fn]), "left")
        XCTAssertEqual(hostKeySpecification(name: "PageUp", modifiers: []), "pageup")
    }

    // MARK: - Helpers

    private func makeRegistry() -> HostSnapshotRegistry {
        HostSnapshotRegistry(limits: HostLimits()) { _ in }
    }

    private func failureCode<Success>(_ result: Result<Success, HostDomainError>) -> HostDomainErrorCode? {
        guard case .failure(let error) = result else {
            return nil
        }
        return error.code
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func makeBinding(token: String, digestInput: HostElementDigestInput) -> HostElementBinding {
        HostElementBinding(
            token: token,
            parentToken: nil,
            depth: 1,
            pid: 4711,
            processStartTime: 1_234_567,
            digestInput: digestInput,
            element: nil,
            observed: HostObservedElement(
                token: token,
                parentToken: nil,
                depth: 1,
                role: digestInput.role,
                subrole: nil,
                axIdentifier: nil,
                label: digestInput.label,
                value: nil,
                placeholder: nil,
                enabled: true,
                focused: false,
                selected: nil,
                frame: nil,
                actions: [.press],
                digest: hostElementDigest(digestInput),
                truncated: []
            )
        )
    }

    private func makeSnapshot(
        registry: HostSnapshotRegistry,
        session: String,
        windowId: CGWindowID,
        capturedAt: Int64 = hostNowMs(),
        imagePath: String? = nil
    ) -> HostSnapshot {
        let id = registry.nextSnapshotId()
        let binding = makeBinding(
            token: "el_\(id)_0",
            digestInput: HostElementDigestInput(role: "AXButton", label: "Send")
        )

        let payload = HostSnapshotPayload(
            snapshotId: id,
            capturedAt: capturedAt,
            target: HostWindowTarget(
                pid: 4711,
                windowId: windowId,
                bundleId: "com.apple.Notes",
                appName: "Notes",
                title: "Untitled",
                bounds: HostRect(x: 0, y: 0, width: 100, height: 100),
                layer: 0,
                zIndex: 3,
                displayId: "1"
            ),
            windowDigest: hostWindowDigest(
                elementDigests: [binding.digest],
                bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
                title: "Untitled"
            ),
            focusedElementToken: nil,
            selectedText: nil,
            image: nil,
            displays: [],
            obscuringRects: [],
            elements: [binding.observed],
            truncated: HostSnapshotTruncation(elements: false, depth: false)
        )

        return HostSnapshot(
            id: id,
            session: session,
            pid: 4711,
            windowId: windowId,
            capturedAt: capturedAt,
            windowDigest: payload.windowDigest,
            payload: payload,
            bindings: [binding],
            imagePath: imagePath
        )
    }
}

// MARK: - Test doubles

private final class FakeNode: HostAccessibilityNode {
    let role: String
    let subrole: String?
    let axIdentifier: String?
    let title: String?
    let label: String?
    let value: String?
    let placeholder: String?
    let enabled: Bool
    let focused: Bool
    let selected: Bool?
    let frameInWindow: CGRect?
    let rawActionNames: [String]
    private let childNodes: [FakeNode]

    var axElement: AXUIElement? { nil }
    var children: [HostAccessibilityNode] { childNodes }

    init(
        role: String,
        subrole: String? = nil,
        axIdentifier: String? = nil,
        title: String? = nil,
        label: String? = nil,
        value: String? = nil,
        placeholder: String? = nil,
        enabled: Bool = true,
        focused: Bool = false,
        selected: Bool? = nil,
        frameInWindow: CGRect? = nil,
        rawActionNames: [String] = [],
        children: [FakeNode] = []
    ) {
        self.role = role
        self.subrole = subrole
        self.axIdentifier = axIdentifier
        self.title = title
        self.label = label
        self.value = value
        self.placeholder = placeholder
        self.enabled = enabled
        self.focused = focused
        self.selected = selected
        self.frameInWindow = frameInWindow
        self.rawActionNames = rawActionNames
        self.childNodes = children
    }
}

private struct FakeBindingProbe: HostElementBindingProbe {
    var alive = true
    var startTime: UInt64 = 1_234_567
    var digestInput: HostElementDigestInput

    init(digestInput: HostElementDigestInput) {
        self.digestInput = digestInput
    }

    func isReferenceAlive(_ binding: HostElementBinding) -> Bool { alive }
    func processStartTime(pid: pid_t) -> UInt64? { startTime }
    func currentDigestInput(_ binding: HostElementBinding) -> HostElementDigestInput? { digestInput }
}

/// Drives `HostProtocolServer.handle(line:)` and collects whole response lines.
/// The lanes are real serial queues, so responses are awaited rather than read.
private final class ServerHarness {
    let server: HostProtocolServer
    private let inbox: LineInbox
    private let imageDirectory: URL

    private final class LineInbox {
        private let lock = NSLock()
        private var lines: [Data] = []

        func append(_ data: Data) {
            lock.lock()
            lines.append(data)
            lock.unlock()
        }

        func take() -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return lines.isEmpty ? nil : lines.removeFirst()
        }
    }

    init() {
        imageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("maka-cu-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)

        let inbox = LineInbox()
        self.inbox = inbox
        server = HostProtocolServer(output: HostOutputWriter { inbox.append($0) })
    }

    deinit {
        try? FileManager.default.removeItem(at: imageDirectory)
    }

    func send(_ line: String) {
        server.handle(line: line)
    }

    func sendHello(protocolVersion: String = "maka.cu/1", imageDir: String? = nil) {
        let directory = imageDir ?? imageDirectory.path
        send("""
        {"jsonrpc":"2.0","id":1,"method":"host.hello","params":{"protocol":"\(protocolVersion)","hostPid":\(ProcessInfo.processInfo.processIdentifier),"imageDir":"\(directory)","allowGlobalPointer":false}}
        """)
    }

    func awaitResponse(timeout: TimeInterval = 2) throws -> [String: Any] {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if let next = inbox.take() {
                return try XCTUnwrap(try JSONSerialization.jsonObject(with: next) as? [String: Any])
            }

            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }

        throw HostHarnessTimeout()
    }
}

private struct HostHarnessTimeout: Error {}
