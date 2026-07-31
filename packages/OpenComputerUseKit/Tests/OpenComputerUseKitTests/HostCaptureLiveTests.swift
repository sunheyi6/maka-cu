import AppKit
import CoreGraphics
import Foundation
import XCTest
@testable import OpenComputerUseKit

/// §12 vectors 47 and 48 — the half of the capture contract no unit test can
/// reach. A bitmap only disagrees with the size it declares once a real
/// compositor has drawn into it, and the executor's own arithmetic agrees with
/// itself either way.
///
///     OPEN_COMPUTER_USE_RUN_CAPTURE_LIVE_TEST=1 \
///         swift test --filter HostCaptureLiveTests
///
/// Opt-in for the same reason `SkyClickLiveTests` is: it photographs whatever is
/// on the machine's screens, and it starts a window of its own so that a machine
/// with an empty desktop cannot turn the sweep into a vacuous pass.
///
/// Vector 47 can only *fail* on a machine whose displays do not all share one
/// backing scale. The defect it names was an output buffer sized from a guessed
/// scale, and where the guess happens to be right there is nothing to catch. So
/// the test sweeps every window on screen rather than only the one it started:
/// on the machine that found this — a 2x built-in beside a 1x external — the
/// windows on the external display are the ones that came back
/// three-quarters transparent, declaring `scale: 2.0` over content drawn at 1.0.
///
/// Every wait here is a semaphore. `wait(for:)` and `RunLoop.run` both spin the
/// main run loop, and a spun run loop thaws exactly the caches and timings a
/// live test is here to catch — the executor's main thread sits in `readLine`
/// and spins nothing.
final class HostCaptureLiveTests: XCTestCase {
    private struct WindowRecord {
        let id: CGWindowID
        let pid: pid_t
        let bounds: CGRect
        let name: String
    }

    /// One capture, measured. `coverage` guards against a frame whose only
    /// content is a pixel in each corner, which would satisfy the bounding box
    /// on its own.
    private struct Measured {
        let label: String
        let declared: CGSize
        let opaqueBox: CGRect
        let coverage: Double
        let declaredScale: Double
        let displayScale: Double

        var fills: Bool {
            opaqueBox == CGRect(origin: .zero, size: declared) && coverage > 0.5
        }

        var description: String {
            "\(label): declared \(Int(declared.width))x\(Int(declared.height))px, "
                + "content \(opaqueBox), coverage \(String(format: "%.4f", coverage)), "
                + "declared scale \(declaredScale) against display scale \(displayScale)"
        }
    }

    // MARK: - §12.47 — an image fills the size it declares

    func testEveryWindowCaptureFillsTheSizeItDeclaresAtTheScaleItDeclares() throws {
        try requireLiveCapture()

        // The fixture guarantees at least one window, so "nothing was captured"
        // cannot pass as "nothing was wrong".
        let fixture = try launchFixture()
        defer { stop(fixture) }

        let imageDirectory = try makeImageDirectory()
        defer { try? FileManager.default.removeItem(at: imageDirectory) }

        let targets = Self.windows().filter { $0.bounds.width >= 64 && $0.bounds.height >= 64 }
        XCTAssertTrue(
            targets.contains { $0.pid == fixture.processIdentifier },
            "the fixture window this test started is not on screen"
        )

        let sweep = SweepResults()
        let done = DispatchSemaphore(value: 0)

        // Off the main thread on purpose: `HostCapture` blocks on a semaphore
        // from a lane in production and spins the run loop when it is called on
        // the main one, and the run loop is what a live test must not lean on.
        Thread.detachNewThread {
            let store = HostImageStore(
                directory: imageDirectory,
                budgetBytes: HostLimits().imageDirBudgetBytes
            )

            for window in targets {
                guard let displayScale = Self.backingScale(containing: window.bounds) else {
                    continue
                }

                for scope in [HostCaptureScope.window, HostCaptureScope.desktop] {
                    let label = "\(window.name.isEmpty ? "window \(window.id)" : window.name) [\(scope.rawValue)]"
                    switch HostCapture.captureWindow(windowId: window.id, scope: scope) {
                    case .failure(let error):
                        // A window can close while the sweep runs; that is not a
                        // geometry failure, but it is recorded so that a machine
                        // where nothing at all could be captured is visible.
                        sweep.addUnreadable("\(label): \(error.code)")
                    case .success(let image):
                        guard case .success(let reference) = store.writePNG(
                            image,
                            namePrefix: "live",
                            logicalWidth: window.bounds.width
                        ) else {
                            sweep.addUnreadable("\(label): image_write_failed")
                            continue
                        }

                        let measure = Self.opaqueBoundingBox(of: image)
                        sweep.add(
                            Measured(
                                label: label,
                                declared: CGSize(width: reference.widthPx, height: reference.heightPx),
                                opaqueBox: measure.box,
                                coverage: measure.coverage,
                                declaredScale: reference.scale,
                                displayScale: displayScale
                            )
                        )
                        store.delete(path: reference.path)
                    }
                }
            }

            done.signal()
        }

        XCTAssertEqual(done.wait(timeout: .now() + 300), .success, "the capture sweep did not finish")

        let measurements = sweep.measurements
        XCTAssertFalse(
            measurements.isEmpty,
            "nothing was captured, so nothing was proved; unreadable: \(sweep.unreadable)"
        )

        for measured in measurements {
            print("capture live test: \(measured.description)")
        }

        let unfilled = measurements.filter { !$0.fills }
        XCTAssertTrue(
            unfilled.isEmpty,
            "an image must be drawn over the whole of its declared size (§6.7):\n"
                + unfilled.map(\.description).joined(separator: "\n")
        )

        // The other half of §6.7. This one catches the same defect through the
        // field rather than through the pixels: a buffer sized at twice the
        // content makes `widthPx / bounds.width` report 2.0 for a window on a 1x
        // display, and every pixel coordinate the model derives is then off by
        // a factor of two.
        let mismatched = measurements.filter { abs($0.declaredScale - $0.displayScale) > 0.001 }
        XCTAssertTrue(
            mismatched.isEmpty,
            "image.scale must be the scaling the content actually has (§6.7):\n"
                + mismatched.map(\.description).joined(separator: "\n")
        )
    }

    // MARK: - §12.48 — screen.capture with no displayId

    func testScreenCaptureWithNoDisplayIdCapturesTheMainDisplayAndSaysSo() throws {
        try requireLiveCapture()

        let imageDirectory = try makeImageDirectory()
        let inbox = ResponseInbox()
        let server = HostProtocolServer(
            output: HostOutputWriter { inbox.append($0) },
            environment: FakeEnvironment()
        )

        server.handle(line: #"""
        {"jsonrpc":"2.0","id":1,"method":"host.hello","params":{"protocol":"\#(makaCuProtocolVersion)","hostPid":\#(ProcessInfo.processInfo.processIdentifier),"imageDir":"\#(imageDirectory.path)","allowGlobalPointer":false}}
        """#)
        _ = try inbox.next()
        server.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"session.begin","params":{"session":"s1","captureScope":"window"}}"#)
        _ = try inbox.next()

        server.handle(line: #"{"jsonrpc":"2.0","id":3,"method":"screen.capture","params":{"session":"s1"}}"#)
        let response = try inbox.next(timeout: 30)

        XCTAssertNil(response["error"], "a request with no displayId is not a parameter error")
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["ok"] as? Bool, true, "\(result)")
        XCTAssertEqual(
            result["displayId"] as? String,
            String(CGMainDisplayID()),
            "the answer names the display that was captured, even when the request did not"
        )

        let image = try XCTUnwrap(result["image"] as? [String: Any])
        let path = try XCTUnwrap(image["path"] as? String)
        let widthPx = try XCTUnwrap(image["widthPx"] as? Int)
        let heightPx = try XCTUnwrap(image["heightPx"] as? Int)
        let scale = try XCTUnwrap(image["scale"] as? Double)

        let onDisk = try XCTUnwrap(NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(onDisk.width, widthPx, "the file is not the size the response declared")
        XCTAssertEqual(onDisk.height, heightPx)

        let measure = Self.opaqueBoundingBox(of: onDisk)
        XCTAssertEqual(measure.box, CGRect(x: 0, y: 0, width: widthPx, height: heightPx))
        XCTAssertGreaterThan(measure.coverage, 0.5)

        let mainScale = try XCTUnwrap(Self.backingScale(ofDisplay: CGMainDisplayID()))
        XCTAssertEqual(scale, mainScale, accuracy: 0.001, "a display is captured at its own pixel density (§6.6)")

        // A named display still answers under the id it was named with, so the
        // default is a default and not a redirect.
        for displayId in hostActiveDisplayIds() {
            server.handle(line: #"{"jsonrpc":"2.0","id":4,"method":"screen.capture","params":{"session":"s1","displayId":"\#(displayId)"}}"#)
            let named = try inbox.next(timeout: 30)
            XCTAssertNil(named["error"], "display \(displayId) is attached")
            XCTAssertEqual((named["result"] as? [String: Any])?["displayId"] as? String, String(displayId))
        }

        server.handle(line: #"{"jsonrpc":"2.0","id":5,"method":"session.end","params":{"session":"s1"}}"#)
        _ = try inbox.next()
        try? FileManager.default.removeItem(at: imageDirectory)
    }

    // MARK: - Helpers

    /// The sweep runs on its own thread and the assertions run on the main one,
    /// so what crosses between them is locked rather than hoped about.
    private final class SweepResults: @unchecked Sendable {
        private let lock = NSLock()
        private var collected: [Measured] = []
        private var failures: [String] = []

        func add(_ measured: Measured) {
            lock.lock()
            collected.append(measured)
            lock.unlock()
        }

        func addUnreadable(_ note: String) {
            lock.lock()
            failures.append(note)
            lock.unlock()
        }

        var measurements: [Measured] {
            lock.lock()
            defer { lock.unlock() }
            return collected
        }

        var unreadable: [String] {
            lock.lock()
            defer { lock.unlock() }
            return failures
        }
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

    private func requireLiveCapture() throws {
        guard ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_RUN_CAPTURE_LIVE_TEST"] == "1" else {
            throw XCTSkip("Set OPEN_COMPUTER_USE_RUN_CAPTURE_LIVE_TEST=1 to run the live capture geometry tests")
        }

        // Preflight rather than request: a prompt here would block the run, and
        // an ungranted process captures the desktop picture and nothing else.
        guard CGPreflightScreenCaptureAccess() else {
            throw XCTSkip("Screen Recording is not granted to the process running these tests")
        }

        // `SCContentFilter` reaches into SkyLight, which asserts if the
        // CoreGraphics connection has never been opened — which is the case in a
        // test bundle that has not touched AppKit yet. The executor is an
        // application and opens it at startup.
        XCTAssertFalse(NSScreen.screens.isEmpty, "a live capture test needs a display")
    }

    private func makeImageDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("maka-cu-capture-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func launchFixture() throws -> Process {
        let executable = Self.packageRoot.appendingPathComponent(".build/debug/OpenComputerUseFixture")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw XCTSkip("Build OpenComputerUseFixture before running the live capture tests")
        }

        let process = Process()
        process.executableURL = executable
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if Self.windows().contains(where: { $0.pid == process.processIdentifier }) {
                return process
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        stop(process)
        throw ComputerUseError.message("the fixture window did not appear")
    }

    private func stop(_ process: Process) {
        guard process.isRunning else {
            return
        }

        process.terminate()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    /// The backing scale of the display a window's centre sits on. The screen is
    /// found through `CGDisplayBounds`, never through `NSScreen.frame`:
    /// `NSScreen.frame` is AppKit's y-up space and a window rectangle is
    /// CoreGraphics' y-down space, and matching one against the other is exactly
    /// the mistake these tests exist to catch.
    private static func backingScale(containing rect: CGRect) -> Double? {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens
            .first { screen in
                guard
                    let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
                else {
                    return false
                }
                return CGDisplayBounds(CGDirectDisplayID(number.uint32Value)).contains(centre)
            }
            .map { Double($0.backingScaleFactor) }
    }

    private static func backingScale(ofDisplay displayId: CGDirectDisplayID) -> Double? {
        NSScreen.screens
            .first { screen in
                (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                    .uint32Value == displayId
            }
            .map { Double($0.backingScaleFactor) }
    }

    /// The rectangle covering every non-transparent pixel, and the fraction of
    /// the bitmap they occupy. Window captures have transparent rounded corners,
    /// so the coverage is a floor rather than an equality; the bounding box is
    /// the assertion that matters, because content drawn at the wrong scale is
    /// anchored at the origin and leaves whole edges empty.
    private static func opaqueBoundingBox(of image: CGImage) -> (box: CGRect, coverage: Double) {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return (.null, 0)
        }

        let full = CGRect(x: 0, y: 0, width: width, height: height)
        context.clear(full)
        context.draw(image, in: full)

        var opaque = 0
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] != 0 {
                opaque += 1
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }

        guard maxX >= 0 else {
            return (.null, 0)
        }

        return (
            CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1),
            Double(opaque) / Double(width * height)
        )
    }

    private static func windows() -> [WindowRecord] {
        let raw = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []

        return raw.compactMap { info in
            guard
                let number = info[kCGWindowNumber as String] as? NSNumber,
                let ownerPID = info[kCGWindowOwnerPID as String] as? NSNumber,
                let layer = info[kCGWindowLayer as String] as? NSNumber,
                layer.intValue == 0,
                let boundsDictionary = info[kCGWindowBounds as String] as? [String: Any],
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                bounds.width > 0,
                bounds.height > 0
            else {
                return nil
            }

            return WindowRecord(
                id: number.uint32Value,
                pid: ownerPID.int32Value,
                bounds: bounds,
                name: info[kCGWindowName as String] as? String ?? ""
            )
        }
    }

    private static let packageRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            url.deleteLastPathComponent()
        }
        return url
    }()
}
