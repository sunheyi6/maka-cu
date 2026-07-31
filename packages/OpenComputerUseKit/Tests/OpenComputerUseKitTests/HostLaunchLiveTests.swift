import AppKit
import CoreGraphics
import Foundation
import XCTest
@testable import OpenComputerUseKit

/// §12 vector 50 — the half of the launch contract no unit test can reach. The
/// configuration test proves what the executor *asked* LaunchServices for; only
/// a cold application on a real desktop proves what it got.
///
///     OPEN_COMPUTER_USE_RUN_LAUNCH_LIVE_TEST=1 \
///         swift test --filter HostLaunchLiveTests
///
/// Opt-in for the reason `HostCaptureLiveTests` is: it starts an application on
/// the machine running it. It needs one that is **not already running**, because
/// `AppDiscovery.resolve` returns a running app without launching anything at
/// all — and a launch that never happened cannot take a foreground, which is a
/// vacuous pass. That is also the most likely explanation for the one cold
/// launch in the original harness run that did not steal focus while its
/// neighbour did.
///
/// Every wait here is a semaphore. `wait(for:)` and `RunLoop.run` both spin the
/// main run loop, and the executor's main thread sits in `readLine` and spins
/// nothing — a spun run loop refreshes exactly the AppKit caches §5.5 says are
/// frozen on a lane, so a live test that leans on one is testing a process that
/// does not exist.
final class HostLaunchLiveTests: XCTestCase {
    /// Ordinary, harmless, and unlikely to be open: the first one that is not
    /// running is the one this test uses, so a machine where the earlier
    /// candidates are already up still has a cold launch to make. The list is
    /// longer than it needs to be because each run consumes one of them — the
    /// application it starts is left running, since this test does not own it.
    private static let candidates = [
        "/System/Applications/Chess.app",
        "/System/Applications/Utilities/Grapher.app",
        "/System/Applications/Image Capture.app",
        "/System/Applications/Stickies.app",
        "/System/Applications/Font Book.app",
        "/System/Applications/Preview.app",
    ]

    func testAColdLaunchNeverOwnsTheFrontWindowAndSaysSoEitherWay() throws {
        guard ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_RUN_LAUNCH_LIVE_TEST"] == "1" else {
            throw XCTSkip("Set OPEN_COMPUTER_USE_RUN_LAUNCH_LIVE_TEST=1 to run the live background launch test")
        }

        // A precondition this test cannot create for itself, so an unmet one is
        // a skip and not a failure: `AppDiscovery.resolve` returns a running
        // application without launching anything, and a launch that never
        // happened cannot take a foreground. Quitting one of the candidates to
        // make room would mean closing an application the user may be using.
        guard let bundle = Self.candidates
            .map(URL.init(fileURLWithPath:))
            .first(where: { FileManager.default.fileExists(atPath: $0.path) && !Self.isRunning($0) })
        else {
            throw XCTSkip(
                "every candidate is already running, so nothing here would be a cold launch — "
                    + "quit one of \(Self.candidates.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "))"
            )
        }

        let name = bundle.deletingPathExtension().lastPathComponent
        let frontBefore = LiveApplicationInventory.frontmostApplicationPid()
        XCTAssertNotNil(frontBefore, "a live launch test needs something on screen to keep the foreground")

        let watcher = ForegroundWatcher()
        let sampling = Thread(block: { watcher.sample(for: 12) })
        sampling.start()

        // Off the main thread on purpose: this is the call `apps.launch` makes
        // from a lane, and `AppDiscovery.resolve` blocks on a semaphore.
        let launched = LaunchOutcome()
        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            launched.result = Result { try AppDiscovery.resolve(name, waitFor: 20) }
            finished.signal()
        }

        XCTAssertEqual(finished.wait(timeout: .now() + 40), .success, "the launch never returned")
        let app = try launched.result?.get() ?? XCTUnwrap(nil as RunningAppDescriptor?)
        watcher.finish()

        let samples = watcher.samples
        print("launch live test: \(name) pid \(app.pid), front layer-0 owner over the launch:")
        for sample in samples {
            print(String(format: "    +%.2fs  pid %d", sample.elapsed, sample.pid))
        }

        // The assertion is over the whole launch, not over its last instant. A
        // single read at the end is what let the original harness call a
        // foreground steal a pass: something else had taken the foreground back
        // by the time it looked.
        XCTAssertFalse(
            samples.contains { $0.pid == app.pid },
            "\(name) owned the front window during a launch that asked not to activate"
        )

        // And the report is the two reads, not the request. Whatever holds the
        // foreground now, the field agrees with the window server.
        let frontAfter = LiveApplicationInventory.frontmostApplicationPid()
        XCTAssertEqual(
            frontAfter == app.pid && frontBefore != app.pid,
            samples.last?.pid == app.pid,
            "foregroundTaken must be computed from the machine, not from what was asked for"
        )
    }

    // MARK: - Helpers

    private final class LaunchOutcome: @unchecked Sendable {
        var result: Result<RunningAppDescriptor, Error>?
    }

    /// The front layer-0 window owner, sampled at 20 Hz for the life of a
    /// launch. Locked rather than hoped about: it is written from the sampling
    /// thread and read from the test's.
    private final class ForegroundWatcher: @unchecked Sendable {
        struct Sample {
            let elapsed: Double
            let pid: pid_t
        }

        private let lock = NSLock()
        private var collected: [Sample] = []
        private var stopped = false

        func sample(for seconds: TimeInterval) {
            let start = Date()
            while Date().timeIntervalSince(start) < seconds {
                lock.lock()
                let done = stopped
                lock.unlock()
                if done {
                    return
                }

                if let pid = LiveApplicationInventory.frontmostApplicationPid() {
                    lock.lock()
                    if collected.last?.pid != pid {
                        collected.append(Sample(elapsed: Date().timeIntervalSince(start), pid: pid))
                    }
                    lock.unlock()
                }

                Thread.sleep(forTimeInterval: 0.05)
            }
        }

        /// Gives the machine a moment past the resolve: an application that
        /// activates itself does it as its first window comes up, which can be
        /// after the process has already registered.
        func finish() {
            Thread.sleep(forTimeInterval: 2)
            lock.lock()
            stopped = true
            lock.unlock()
        }

        var samples: [Sample] {
            lock.lock()
            defer { lock.unlock() }
            return collected
        }
    }

    private static func isRunning(_ bundle: URL) -> Bool {
        let identifier = Bundle(url: bundle)?.bundleIdentifier
        return LiveApplicationInventory.runningApplications().contains { app in
            app.bundleIdentifier == identifier || app.bundleURL?.standardizedFileURL == bundle.standardizedFileURL
        }
    }
}
