import ApplicationServices
import CoreGraphics
import Foundation
import XCTest
@testable import OpenComputerUseKit

/// §12 vectors 56 and 57, and the half of 58 that has no desktop in it.
///
/// The parts of window management that can be decided without a machine: what a
/// requested geometry compares equal to, which attribute each action writes, when
/// the window server counts as having caught up, and which requests never reach
/// an application at all.
final class HostWindowDispatchTests: XCTestCase {
    // MARK: - Canonical geometry (§6.5)

    /// §4.3 already compares a frame at whole logical points, and the readback
    /// comparison uses the same resolution deliberately: two resolutions for one
    /// rectangle is how an executor refuses a dispatch against a window nothing
    /// had moved.
    func testAGeometryIsComparedAtWholeLogicalPoints() {
        XCTAssertEqual(hostCanonicalPoint(CGPoint(x: 220, y: 164)), "[220,164]")
        XCTAssertEqual(hostCanonicalSize(CGSize(width: 674, height: 408)), "[674,408]")

        // Sub-pixel noise on a scaled display is the same answer, not a third one.
        XCTAssertEqual(
            hostCanonicalPoint(CGPoint(x: 220.4, y: 163.5)),
            hostCanonicalPoint(CGPoint(x: 220, y: 164))
        )

        // The display above the main one on this machine starts at y = -1080.
        XCTAssertEqual(hostCanonicalPoint(CGPoint(x: -193, y: -1080)), "[-193,-1080]")
    }

    /// A readback crosses a process boundary, so the values `Int(_:)` traps on
    /// have to be survivable rather than merely unlikely.
    func testAnUnrepresentableGeometryDoesNotTrap() {
        XCTAssertEqual(hostWholePoints(.nan), "out_of_range")
        XCTAssertEqual(hostWholePoints(.infinity), "out_of_range")
        XCTAssertEqual(hostWholePoints(-.infinity), "out_of_range")
        XCTAssertEqual(hostWholePoints(1e300), "out_of_range")
        XCTAssertEqual(hostWholePoints(-1e300), "out_of_range")
    }

    // MARK: - Which attribute an action writes (§6.1)

    func testEachWindowActionWritesItsOwnAttribute() throws {
        XCTAssertEqual(
            try XCTUnwrap(hostWindowSubject(for: .moveWindow(HostPoint(x: 1, y: 2)))).attribute,
            kAXPositionAttribute
        )
        XCTAssertEqual(
            try XCTUnwrap(hostWindowSubject(for: .resizeWindow(HostSize(width: 3, height: 4)))).attribute,
            kAXSizeAttribute
        )
        XCTAssertEqual(
            try XCTUnwrap(hostWindowSubject(for: .minimizeWindow)).attribute,
            kAXMinimizedAttribute
        )

        // A move writes the origin and a resize the extent, and neither writes
        // the other: an executor that read the pair and wrote the pair back
        // would move a window every time it was asked to resize one.
        XCTAssertNotEqual(
            try XCTUnwrap(hostWindowSubject(for: .moveWindow(HostPoint(x: 1, y: 2)))).attribute,
            try XCTUnwrap(hostWindowSubject(for: .resizeWindow(HostSize(width: 3, height: 4)))).attribute
        )

        for action in [
            HostElementAction.click(button: .left, count: 1),
            .setValue("x"),
            .selectText("x"),
            .secondaryAction(.raise),
            .scroll(direction: .down, pages: 1),
        ] {
            XCTAssertNil(hostWindowSubject(for: action), "\(action) is not a window action")
            XCTAssertFalse(action.addressesTheWindowItself)
        }

        for action in [
            HostElementAction.moveWindow(HostPoint(x: 0, y: 0)),
            .resizeWindow(HostSize(width: 1, height: 1)),
            .minimizeWindow,
        ] {
            XCTAssertTrue(action.addressesTheWindowItself)
        }
    }

    // MARK: - Waiting for the window server (§6.1, vector 58)

    /// The window server is 26–172 ms behind the application, and everything
    /// downstream reads the window server. Agreement ends the wait immediately;
    /// it does not sit out the ceiling.
    func testTheWaitEndsAsSoonAsTheWindowServerAgrees() {
        let subject = hostWindowSubject(for: .moveWindow(HostPoint(x: 220, y: 164)))!
        let clock = ManualClock()
        var looks = 0
        var slept: [TimeInterval] = []

        let agreed = hostAwaitWindowServerAgreement(
            ceilingMs: 1000,
            pollMs: 5,
            readback: "[220,164]",
            subject: subject,
            sample: {
                looks += 1
                // The list reports the old origin for the first three looks —
                // 15 ms at a 5 ms poll, which is Calculator's 26 ms rounded down.
                return looks < 4
                    ? CGRect(x: 280, y: 164, width: 674, height: 408)
                    : CGRect(x: 220, y: 164, width: 674, height: 408)
            },
            now: clock.read,
            sleep: { slept.append($0); clock.advance($0) }
        )

        XCTAssertTrue(agreed)
        XCTAssertEqual(looks, 4, "it stops on the look that agrees")
        XCTAssertEqual(slept.count, 3, "and does not wait again after agreeing")
    }

    /// Waiting the bound out is a fact about the machine, not an error, and the
    /// executor must not spend more than the bound discovering it.
    ///
    /// The assertion is on the clock rather than on a count of looks: the budget
    /// is spent in 5 ms steps, and 5 ms cannot be added twenty times in binary
    /// floating point without landing either side of 100. What is being claimed
    /// is that the wait is bounded, and that is what is asserted.
    func testTheWaitGivesUpAtTheCeilingAndSaysSo() {
        let subject = hostWindowSubject(for: .moveWindow(HostPoint(x: 220, y: 164)))!
        let clock = ManualClock()
        let started = clock.read()
        var looks = 0

        let agreed = hostAwaitWindowServerAgreement(
            ceilingMs: 100,
            pollMs: 5,
            readback: "[220,164]",
            subject: subject,
            sample: {
                looks += 1
                return CGRect(x: 280, y: 164, width: 674, height: 408)
            },
            now: clock.read,
            sleep: { clock.advance($0) }
        )

        XCTAssertFalse(agreed)
        XCTAssertLessThanOrEqual(
            clock.read().timeIntervalSince(started),
            0.1,
            "the ceiling is a ceiling: the wait never runs past it"
        )
        XCTAssertGreaterThanOrEqual(looks, 19, "and it does keep looking until the budget is gone")
    }

    /// A window that has left the on-screen list is what a minimise looks like
    /// from the window server, and it is the *only* thing it has to say about
    /// one. The move and resize subjects must read the same absence as "not yet".
    func testWhatEachSubjectAcceptsFromTheWindowServer() throws {
        let move = try XCTUnwrap(hostWindowSubject(for: .moveWindow(HostPoint(x: 220, y: 164))))
        XCTAssertTrue(move.serverAgrees(CGRect(x: 220, y: 164, width: 10, height: 10), "[220,164]"))
        XCTAssertFalse(move.serverAgrees(CGRect(x: 280, y: 164, width: 10, height: 10), "[220,164]"))
        XCTAssertFalse(move.serverAgrees(nil, "[220,164]"))

        // It waits for the *readback*, not for the request: a clamped move lands
        // somewhere neither side asked for, and the window server will never
        // agree with the request.
        XCTAssertTrue(move.serverAgrees(CGRect(x: 1687, y: -52, width: 10, height: 10), "[1687,-52]"))

        let resize = try XCTUnwrap(hostWindowSubject(for: .resizeWindow(HostSize(width: 753, height: 499))))
        XCTAssertTrue(resize.serverAgrees(CGRect(x: 0, y: 0, width: 753, height: 499), "[753,499]"))
        XCTAssertFalse(resize.serverAgrees(CGRect(x: 0, y: 0, width: 673, height: 439), "[753,499]"))

        let minimize = try XCTUnwrap(hostWindowSubject(for: .minimizeWindow))
        XCTAssertTrue(minimize.serverAgrees(nil, "true"))
        XCTAssertFalse(minimize.serverAgrees(CGRect(x: 0, y: 0, width: 10, height: 10), "true"))
    }

    // MARK: - The verdict (§6.5, vector 57)

    /// The three arms, over geometry rather than over text. The middle one is the
    /// case macOS produces on its own — measured, `(99999, 300)` came back
    /// `(1687, -52)` and a 10 × 10 resize came back 115 × 46 — and it is neither
    /// `confirmed` (the window is not where it was asked to be) nor
    /// `suspected_noop` (it moved).
    func testAClampedMoveIsNeitherConfirmedNorANoop() {
        let landed = hostEffectFromValueReadback(
            requested: hostCanonicalPoint(CGPoint(x: 220, y: 204)),
            previous: hostCanonicalPoint(CGPoint(x: 280, y: 164)),
            readback: hostCanonicalPoint(CGPoint(x: 220, y: 204))
        )
        XCTAssertEqual(landed.effect, .confirmed)
        XCTAssertEqual(landed.verification.method, .valueReadback)
        XCTAssertTrue(landed.verification.observedChange)

        let clamped = hostEffectFromValueReadback(
            requested: hostCanonicalPoint(CGPoint(x: 99_999, y: 300)),
            previous: hostCanonicalPoint(CGPoint(x: 280, y: -400)),
            readback: hostCanonicalPoint(CGPoint(x: 1687, y: -52))
        )
        XCTAssertEqual(clamped.effect, .unverifiable, "it moved, but not to where it was asked")
        XCTAssertEqual(clamped.verification.method, .valueReadback, "and the executor did look")
        XCTAssertTrue(clamped.verification.observedChange)

        let refusedByTheApplication = hostEffectFromValueReadback(
            requested: hostCanonicalSize(CGSize(width: 754, height: 468)),
            previous: hostCanonicalSize(CGSize(width: 674, height: 408)),
            readback: hostCanonicalSize(CGSize(width: 674, height: 408))
        )
        XCTAssertEqual(refusedByTheApplication.effect, .suspectedNoop)
        XCTAssertFalse(refusedByTheApplication.verification.observedChange)

        // Asking for the position a window already has is `confirmed` with
        // nothing observed to have changed, exactly as `set_value` is.
        let alreadyThere = hostEffectFromValueReadback(
            requested: hostCanonicalPoint(CGPoint(x: 280, y: 164)),
            previous: hostCanonicalPoint(CGPoint(x: 280, y: 164)),
            readback: hostCanonicalPoint(CGPoint(x: 280, y: 164))
        )
        XCTAssertEqual(alreadyThere.effect, .confirmed)
        XCTAssertFalse(alreadyThere.verification.observedChange)
    }

    // MARK: - The wire (§2, §6.1)

    func testTheHandshakeAdvertisesTheWindowActions() throws {
        let harness = ServerHarness()
        harness.sendHello()
        let result = try harness.awaitResult()

        let capabilities = try XCTUnwrap(result["capabilities"] as? [String: Any])
        let actions = try XCTUnwrap(capabilities["elementActions"] as? [String])
        for action in ["move_window", "resize_window", "minimize_window"] {
            XCTAssertTrue(actions.contains(action), "\(action) must travel in the handshake")
        }

        // §6.1 — a capability the host can read but never use is worse than a
        // missing one, and restoring a minimized window activates its
        // application, so it is absent rather than advertised.
        XCTAssertFalse(actions.contains("unminimize_window"))
    }

    /// §6.1 — the executor does not clamp, so there is nothing here to validate a
    /// position against: negative coordinates name the display above the main one
    /// and off-screen is a request macOS answers for itself. What is rejected is
    /// a number that is not a geometry.
    ///
    /// `field` is `nil` for the rows JSON itself refuses. `1e400` is not a
    /// representable `Double`, and Foundation rejects the whole document rather
    /// than handing the decoder an infinity — so the executor's own `isFinite`
    /// guard is unreachable from the wire. It stays, for the reason
    /// `postKeyEvent`'s unreachable stroke guard stays: the alternative to
    /// rejecting a non-finite position is writing one, and `AXValueCreate` would
    /// take it.
    func testAGeometryThatIsNotOneIsRejectedAtTheField() throws {
        let cases: [(action: String, field: String?)] = [
            (#"{"kind":"resize_window","size":{"width":-1,"height":10}}"#, "size"),
            (#"{"kind":"resize_window","size":{"width":10,"height":-1}}"#, "size"),
            (#"{"kind":"move_window","position":{"x":0}}"#, "y"),
            (#"{"kind":"move_window"}"#, "position"),
            (#"{"kind":"resize_window"}"#, "size"),
            (#"{"kind":"unminimize_window"}"#, "kind"),
            (#"{"kind":"maximize_window"}"#, "kind"),
            (#"{"kind":"move_window","position":{"x":1e400,"y":0}}"#, nil),
            (#"{"kind":"resize_window","size":{"width":1e400,"height":10}}"#, nil),
        ]

        for (action, field) in cases {
            let harness = ServerHarness()
            try harness.begin()
            harness.send(#"""
            {"jsonrpc":"2.0","id":7,"method":"dispatch.element","params":{"session":"s1","snapshotId":"snap_x","toolCallId":"call_1","elementToken":"el_x","expectElementDigest":"sha256:00","action":\#(action)}}
            """#)

            let error = try XCTUnwrap(try harness.awaitResponse()["error"] as? [String: Any], action)
            XCTAssertEqual(error["code"] as? Int, -32602, action)
            if let field {
                XCTAssertEqual((error["data"] as? [String: Any])?["field"] as? String, field, action)
            }
        }
    }

    /// A legal geometry decodes and reaches the frame-binding rules, so the
    /// vector above is testing the geometry and not the whole request.
    func testALegalGeometryGetsPastTheDecoder() throws {
        let harness = ServerHarness()
        try harness.begin()
        harness.send(#"""
        {"jsonrpc":"2.0","id":7,"method":"dispatch.element","params":{"session":"s1","snapshotId":"snap_x","toolCallId":"call_1","elementToken":"el_x","expectElementDigest":"sha256:00","action":{"kind":"move_window","position":{"x":-193,"y":-1080}}}}
        """#)

        let result = try harness.awaitResult()
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertEqual(
            (result["error"] as? [String: Any])?["code"] as? String,
            "snapshot_unknown",
            "a position on the display above the main one is a position, not a bad field"
        )
    }

    // MARK: - Occlusion does not apply (§6.1, vector 56)

    /// A window action acts on no pixel: it moves the window and everything drawn
    /// in it, sheet included. A covered window is exactly the window a model
    /// wants to move, and an application `apps.launch` started begins at the
    /// bottom of the z-order — applying occlusion here would refuse window
    /// management on every freshly launched application.
    ///
    /// The pairing is what makes it a vector rather than an assertion: the same
    /// snapshot, the same covering window, and a click that *is* refused.
    func testOcclusionRefusesAClickAndIsNotConsultedForAWindowAction() throws {
        for (action, expected) in [
            (#"{"kind":"click","button":"left"}"#, "window_occluded"),
            (#"{"kind":"move_window","position":{"x":10,"y":10}}"#, "element_not_actionable"),
            (#"{"kind":"resize_window","size":{"width":10,"height":10}}"#, "element_not_actionable"),
            (#"{"kind":"minimize_window"}"#, "element_not_actionable"),
        ] {
            var environment = FakeEnvironment()
            let target = hostTestWindow(windowId: 1, zIndex: 3)
            // A window of the same application, in front, covering the element.
            let sheet = hostTestWindow(windowId: 2, zIndex: 9)
            environment.windows = [sheet, target]

            let harness = ServerHarness(environment: environment)
            try harness.begin()

            let snapshot = hostTestSnapshot(
                registry: harness.server.currentRegistry(),
                session: "s1",
                window: target,
                elementFrame: HostRect(x: 10, y: 10, width: 20, height: 20),
                element: hostTestElement()
            )
            harness.install(snapshot)

            let binding = try XCTUnwrap(snapshot.payload.elements.first)
            harness.send(#"""
            {"jsonrpc":"2.0","id":8,"method":"dispatch.element","params":{"session":"s1","snapshotId":"\#(snapshot.id)","toolCallId":"call_1","elementToken":"\#(binding.token)","expectElementDigest":"\#(binding.digest)","action":\#(action)}}
            """#)

            let result = try harness.awaitResult()
            XCTAssertEqual(
                (result["error"] as? [String: Any])?["code"] as? String,
                expected,
                action
            )
        }
    }

    /// §5.3 — a window's position is the one geometry this wire states in screen
    /// points, and every `element.frame` is window-local. A non-root target would
    /// leave the executor guessing which space it was handed, so it is refused.
    ///
    /// The fixture binding sits at `depth == 1`, which is the case being refused.
    /// Its live counterpart is the other half: the same action against the root
    /// of a real window succeeds, so this is a gate and not a blanket refusal.
    func testAWindowActionAgainstSomethingThatIsNotTheWindowIsRefused() throws {
        var environment = FakeEnvironment()
        environment.windows = [hostTestWindow()]

        let harness = ServerHarness(environment: environment)
        try harness.begin()

        let snapshot = hostTestSnapshot(
            registry: harness.server.currentRegistry(),
            session: "s1",
            element: hostTestElement()
        )
        harness.install(snapshot)

        let binding = try XCTUnwrap(snapshot.payload.elements.first)
        XCTAssertEqual(binding.depth, 1, "the fixture element is inside the window, not the window")

        harness.send(#"""
        {"jsonrpc":"2.0","id":8,"method":"dispatch.element","params":{"session":"s1","snapshotId":"\#(snapshot.id)","toolCallId":"call_1","elementToken":"\#(binding.token)","expectElementDigest":"\#(binding.digest)","action":{"kind":"move_window","position":{"x":10,"y":10}}}}
        """#)

        let result = try harness.awaitResult()
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertEqual((result["error"] as? [String: Any])?["code"] as? String, "element_not_actionable")

        // §6.5 — a refusal still carries all four declared fields.
        XCTAssertEqual(result["outcome"] as? String, "refused")
        XCTAssertEqual(result["tier"] as? String, "ax")
        XCTAssertEqual(result["path"] as? String, "none")
        XCTAssertEqual(result["effect"] as? String, "unverifiable")
        XCTAssertEqual((result["verification"] as? [String: Any])?["method"] as? String, "none")
    }
}
