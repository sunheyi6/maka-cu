import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import XCTest
@testable import OpenComputerUseKit

/// §12 vector 52 — the half of `dispatch.point`'s anchor that no unit test can
/// reach: whether the executor's two ends of §4.3 read the same live window the
/// same way.
///
///     OPEN_COMPUTER_USE_RUN_POINT_LIVE_TEST=1 \
///         swift test --filter HostPointDispatchLiveTests
///
/// Every unit vector for point dispatch installs a snapshot whose digest the
/// fixture computed, and verifies it against a probe that answers from the
/// record. The recompute therefore always agreed with itself, and the executor
/// shipped with the walk and the probe disagreeing about the snapshot root:
/// observe, then dispatch a point at the frame that observation just handed you,
/// and the answer was `window_changed` — on every application, on both displays,
/// with nothing on screen having moved. Point dispatch was unreachable in full,
/// and the whole suite was green.
///
/// So this test does the one thing that catches it: it observes a real window and
/// immediately dispatches a point against it. Nothing changed in between, so
/// `window_changed` is a wrong answer by construction.
///
/// Calculator is the target because it has no clock, no cursor and no animation
/// in it — a window that changes on its own would make `window_changed` a correct
/// answer and the test meaningless. It is launched in the background and left
/// running: this test does not own it.
///
/// Every wait here is a semaphore. `wait(for:)` and `RunLoop.run` both spin the
/// main run loop, which thaws exactly the timings a live test exists to catch —
/// the executor's main thread sits in `readLine` and spins nothing.
final class HostPointDispatchLiveTests: XCTestCase {
    func testAPointDispatchAgainstTheFrameJustObservedIsNotWindowChanged() throws {
        guard ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_RUN_POINT_LIVE_TEST"] == "1" else {
            throw XCTSkip("Set OPEN_COMPUTER_USE_RUN_POINT_LIVE_TEST=1 to run the live point dispatch test")
        }

        // `AXIsProcessTrusted` asks; the prompting variant would block the run on
        // a dialog nobody is there to answer.
        guard AXIsProcessTrusted() else {
            throw XCTSkip("Accessibility is not granted to the process running these tests")
        }
        guard PermissionDiagnostics.current().screenCaptureGranted else {
            throw XCTSkip("Screen Recording is not granted, and `image_px` needs a captured image")
        }
        guard !hostScreenIsLocked() else {
            throw XCTSkip("The screen is locked, so the tree is the menu bar and nothing else")
        }

        let app = try backgroundLaunchedCalculator()
        let window = try XCTUnwrap(try windowOf(pid: app.pid), "Calculator came up with no window to observe")
        let frontBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier

        let imageDirectory = try makeImageDirectory()
        defer { try? FileManager.default.removeItem(at: imageDirectory) }

        let inbox = ResponseInbox()
        let server = HostProtocolServer(
            output: HostOutputWriter { inbox.append($0) },
            environment: HostLiveEnvironment()
        )

        // `allowGlobalPointer` is false, as it is in production: no cursor warp.
        server.handle(line: #"""
        {"jsonrpc":"2.0","id":1,"method":"host.hello","params":{"protocol":"\#(makaCuProtocolVersion)","hostPid":\#(ProcessInfo.processInfo.processIdentifier),"imageDir":"\#(imageDirectory.path)","allowGlobalPointer":false}}
        """#)
        _ = try inbox.next()
        server.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"session.begin","params":{"session":"s1","captureScope":"window"}}"#)
        _ = try inbox.next()

        // An image, because `image_px` is only meaningful against the image the
        // quoted snapshot carried.
        server.handle(line: #"""
        {"jsonrpc":"2.0","id":3,"method":"observe","params":{"session":"s1","target":{"kind":"window","pid":\#(window.pid),"windowId":\#(window.windowId)},"includeImage":true}}
        """#)
        let observed = try inbox.next(timeout: 30)
        let observation = try XCTUnwrap(observed["result"] as? [String: Any])
        guard observation["ok"] as? Bool == true else {
            return XCTFail("observe: \((observation["error"] as? [String: Any])?["code"] ?? "?")")
        }

        let snapshot = try XCTUnwrap(observation["snapshot"] as? [String: Any])
        let snapshotId = try XCTUnwrap(snapshot["snapshotId"] as? String)
        let windowDigest = try XCTUnwrap(snapshot["windowDigest"] as? String)
        let image = try XCTUnwrap(snapshot["image"] as? [String: Any])
        let widthPx = try XCTUnwrap(image["widthPx"] as? Int)
        let heightPx = try XCTUnwrap(image["heightPx"] as? Int)
        let centre = (x: Double(widthPx) / 2, y: Double(heightPx) / 2)

        // 1. The reproduction, exactly: a move against the frame just handed
        //    over. It is refused, because a pointer move has no target-bound form
        //    and `allowGlobalPointer` is false — but it is refused for *that*,
        //    after the window anchor was recomputed and held. `window_changed`
        //    here is the executor disagreeing with its own observation.
        server.handle(line: #"""
        {"jsonrpc":"2.0","id":4,"method":"dispatch.point","params":{"session":"s1","snapshotId":"\#(snapshotId)","toolCallId":"call_move","expectWindowDigest":"\#(windowDigest)","point":{"x":\#(centre.x),"y":\#(centre.y)},"space":"image_px","action":{"kind":"move"}}}
        """#)
        let moved = try XCTUnwrap(try inbox.next(timeout: 30)["result"] as? [String: Any])
        let moveCode = (moved["error"] as? [String: Any])?["code"] as? String

        XCTAssertNotEqual(
            moveCode,
            "window_changed",
            "nothing moved between the observation and the dispatch, so the anchor it recorded must still hold"
        )
        XCTAssertEqual(moveCode, "dispatch_refused", "a move without a global pointer is refused for the pointer")
        XCTAssertEqual(
            ((moved["error"] as? [String: Any])?["detail"] as? [String: Any])?["wouldRequirePath"] as? String,
            "cg_event_global"
        )

        // 2. §4.1 — that refusal did not spend the frame, so the same snapshot
        //    can carry a dispatch that actually posts. A scroll, because
        //    Calculator has nothing to scroll: the event is delivered to the pid
        //    and the window is left exactly as the user had it.
        //
        //    `occlusionPolicy: "none"` because the anchor is the subject here and
        //    the desktop's stacking is not. Point dispatch defaults to `"any"` —
        //    correct, a pixel belongs to whatever is on top of it — but a
        //    background-launched window starts at the bottom of the z-order, so
        //    the default would make this assertion a report on what the user
        //    happened to have open rather than on the executor.
        server.handle(line: #"""
        {"jsonrpc":"2.0","id":5,"method":"dispatch.point","params":{"session":"s1","snapshotId":"\#(snapshotId)","toolCallId":"call_scroll","expectWindowDigest":"\#(windowDigest)","point":{"x":\#(centre.x),"y":\#(centre.y)},"space":"image_px","occlusionPolicy":"none","action":{"kind":"scroll","direction":"down","pages":1}}}
        """#)
        let scrolled = try XCTUnwrap(try inbox.next(timeout: 30)["result"] as? [String: Any])

        XCTAssertNotEqual(
            (scrolled["error"] as? [String: Any])?["code"] as? String,
            "window_changed",
            "the anchor has to hold all the way to a dispatch, not merely to the path table"
        )
        XCTAssertEqual(scrolled["ok"] as? Bool, true, "\(scrolled)")
        XCTAssertEqual(scrolled["outcome"] as? String, "ok")
        XCTAssertEqual(scrolled["path"] as? String, "cg_event_pid", "target-bound, and the cursor never moved")
        XCTAssertEqual(scrolled["tier"] as? String, "coordinate-background")

        // Nothing in either dispatch may take the foreground.
        XCTAssertEqual(
            NSWorkspace.shared.frontmostApplication?.processIdentifier,
            frontBefore,
            "a background dispatch does not change who is in front"
        )

        server.handle(line: #"{"jsonrpc":"2.0","id":99,"method":"session.end","params":{"session":"s1"}}"#)
        _ = try inbox.next()
    }

    // MARK: - Helpers

    /// Calculator, running, without having taken the foreground to get there. It
    /// is left running: quitting an application the user may have opened is a
    /// side effect a test has no business having.
    private func backgroundLaunchedCalculator() throws -> RunningAppDescriptor {
        guard FileManager.default.fileExists(atPath: "/System/Applications/Calculator.app") else {
            throw XCTSkip("Calculator is not installed")
        }

        let resolved = Outcome()
        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            resolved.result = Result { try AppDiscovery.resolve("Calculator", waitFor: 20) }
            finished.signal()
        }

        guard finished.wait(timeout: .now() + 40) == .success else {
            throw ComputerUseError.message("Calculator never resolved")
        }
        return try XCTUnwrap(resolved.result).get()
    }

    /// Its on-screen ordinary window, waited for: a launch returns before the
    /// window is mapped, measured at 1.3–3.2 s against 2.3–4.5 s (§5.7).
    private func windowOf(pid: pid_t) throws -> HostWindowInfo? {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let windows = HostWindowInventory.onScreenWindows()
                .filter { $0.pid == pid && $0.layer == 0 && $0.bounds.width > 64 && $0.bounds.height > 64 }
            if let first = windows.first {
                return first
            }
            Thread.sleep(forTimeInterval: 0.2)
        }

        return nil
    }

    private func makeImageDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("maka-cu-point-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private final class Outcome: @unchecked Sendable {
        var result: Result<RunningAppDescriptor, Error>?
    }

    /// Line-delimited responses collected off whichever lane produced them, and
    /// handed to the main thread through a semaphore rather than a run loop.
    private final class ResponseInbox: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [Data] = []
        private let arrived = DispatchSemaphore(value: 0)

        func append(_ data: Data) {
            lock.lock()
            lines.append(data)
            lock.unlock()
            arrived.signal()
        }

        func next(timeout: TimeInterval = 5) throws -> [String: Any] {
            guard arrived.wait(timeout: .now() + timeout) == .success else {
                throw ComputerUseError.message("no response within \(timeout)s")
            }

            lock.lock()
            let data = lines.removeFirst()
            lock.unlock()
            return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
    }
}
