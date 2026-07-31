import CoreGraphics
import Foundation
import XCTest
@testable import OpenComputerUseKit

// Shared doubles for the `maka.cu/2` conformance vectors. Everything here stands
// in for the live machine so the §4 binding rules can be asserted without a
// desktop; nothing here fakes protocol logic.

/// A tree node with no Accessibility behind it.
final class FakeNode: HostAccessibilityNode {
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

/// Answers E1–E3 from configured state. With no `override` it reports exactly
/// what the binding recorded, so a dispatch that should pass the binding check
/// does, and a test that expects a refusal has to say which check fails.
struct FakeBindingProbe: HostElementBindingProbe {
    var alive = true
    var startTime: UInt64? = hostTestProcessStartTime
    var override: HostElementDigestInput?

    init(override: HostElementDigestInput? = nil) {
        self.override = override
    }

    func isReferenceAlive(_ binding: HostElementBinding) -> Bool { alive }
    func processStartTime(pid: pid_t) -> UInt64? { startTime }
    func currentDigestInput(_ binding: HostElementBinding) -> HostElementDigestInput? {
        override ?? binding.digestInput
    }
}

/// Records what the executor asked the machine to do, so a test can assert that
/// a refusal posted nothing at all.
final class PointEventLog {
    private let lock = NSLock()
    private(set) var posted: [(action: HostPointAction, point: CGPoint, path: HostDispatchPath)] = []
    /// When set, the post throws — the executor's "attempted, the OS said no".
    var failure: Error?

    func record(action: HostPointAction, point: CGPoint, path: HostDispatchPath) throws {
        lock.lock()
        posted.append((action: action, point: point, path: path))
        lock.unlock()

        if let failure {
            throw failure
        }
    }
}

/// Records what `dispatch.key` asked the machine to do about focus, and decides
/// what the machine does with it — so a test can tell "the executor never asked"
/// from "it asked and the element would not take focus".
final class FocusRequestLog {
    private let lock = NSLock()
    private var requests: [AXUIElement] = []
    private var granted: AXUIElement?

    /// The `kAXFocused` write itself is refused.
    var writeSucceeds = true
    /// The write is accepted *and* focus follows. `false` is the application that
    /// answers `AXError.success` and leaves focus where it was — the reason the
    /// executor re-reads instead of trusting the write.
    var focusFollows = true

    var requested: [AXUIElement] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    var currentFocus: AXUIElement? {
        lock.lock()
        defer { lock.unlock() }
        return granted
    }

    func record(_ element: AXUIElement) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        requests.append(element)

        guard writeSucceeds else {
            return false
        }

        if focusFollows {
            granted = element
        }
        return true
    }
}

/// Records the keys the executor posted, so a refusal can be asserted to have
/// posted nothing — and so a passing dispatch does not type into whatever real
/// process happens to hold the fixture pid.
final class KeyEventLog {
    private let lock = NSLock()
    private(set) var posted: [HostKeyAction] = []
    /// When set, the post throws — the executor's "attempted, the OS said no".
    var failure: Error?

    func record(_ action: HostKeyAction) throws {
        lock.lock()
        posted.append(action)
        lock.unlock()

        if let failure {
            throw failure
        }
    }
}

struct FakeEnvironment: HostSystemEnvironment {
    var locked = false
    var accessibilityTrusted = true
    var screenCaptureGranted = true
    var apps: [HostRunningApp] = []
    var windows: [HostWindowInfo] = []
    var probe = FakeBindingProbe()
    /// Left `nil` by default: most tests assert a refusal that happens before the
    /// element is touched. The `dispatch.key` vectors that need a real
    /// `AXUIElement` use `hostTestElement`.
    var focused: AXUIElement?
    var windowElement: AXUIElement?
    var pointEvents = PointEventLog()
    var keyEvents = KeyEventLog()
    var focusRequests = FocusRequestLog()

    func screenIsLocked() -> Bool { locked }

    func permissions() -> PermissionDiagnostics {
        PermissionDiagnostics(
            accessibilityTrusted: accessibilityTrusted,
            screenCaptureGranted: screenCaptureGranted
        )
    }

    func runningApps() -> [HostRunningApp] { apps }
    func onScreenWindows() -> [HostWindowInfo] { windows }

    func windowElement(pid: pid_t, windowId: CGWindowID, bounds: CGRect) -> AXUIElement? { windowElement }
    func focusedElement(pid: pid_t) -> AXUIElement? { focusRequests.currentFocus ?? focused }
    func setFocusedElement(_ element: AXUIElement, pid: pid_t) -> Bool { focusRequests.record(element) }
    func bindingProbe(windowBounds: CGRect) -> HostElementBindingProbe { probe }

    func postPointEvent(
        _ action: HostPointAction,
        at point: CGPoint,
        from start: CGPoint?,
        pid: pid_t,
        path: HostDispatchPath
    ) throws {
        try pointEvents.record(action: action, point: point, path: path)
    }

    func postKeyEvent(_ action: HostKeyAction, pid: pid_t) throws {
        try keyEvents.record(action)
    }
}

// MARK: - Fixture values

let hostTestPid: pid_t = 4711
let hostTestProcessStartTime: UInt64 = 1_234_567
let hostTestWindowBounds = CGRect(x: 0, y: 0, width: 100, height: 100)
let hostTestWindowTitle = "Untitled"
let hostTestAppId = "com.apple.Notes"

/// A real `AXUIElement`, needed by the `dispatch.key` vectors: `CFEqual` is what
/// the focus check compares with, and it has no fake. Creating an application
/// element neither requires Accessibility nor touches the process — it is an
/// opaque handle, used here only for its identity, so a test keeps the instance
/// it made and hands the *same* one to the binding and to the environment.
func hostTestElement(pid: pid_t = hostTestPid) -> AXUIElement {
    AXUIElementCreateApplication(pid)
}

func hostTestWindow(
    windowId: CGWindowID = 1,
    pid: pid_t = hostTestPid,
    appId: String = hostTestAppId,
    bounds: CGRect = hostTestWindowBounds,
    title: String? = hostTestWindowTitle,
    layer: Int = 0,
    zIndex: Int = 3
) -> HostWindowInfo {
    HostWindowInfo(
        pid: pid,
        windowId: windowId,
        appId: appId,
        appName: "Notes",
        title: title,
        bounds: bounds,
        layer: layer,
        zIndex: zIndex,
        onScreen: true,
        displayId: "1"
    )
}

func hostTestBinding(
    token: String,
    digestInput: HostElementDigestInput,
    enabled: Bool = true,
    frame: HostRect? = nil,
    element: AXUIElement? = nil
) -> HostElementBinding {
    HostElementBinding(
        token: token,
        parentToken: nil,
        depth: 1,
        pid: hostTestPid,
        processStartTime: hostTestProcessStartTime,
        digestInput: digestInput,
        element: element,
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
            enabled: enabled,
            focused: false,
            selected: nil,
            frame: frame,
            actions: [.press],
            digest: hostElementDigest(digestInput),
            truncated: []
        )
    )
}

/// A snapshot of `window`, carrying one element and a window digest computed the
/// way `dispatch.point`'s live check recomputes it, so an unchanged window
/// matches and a changed one does not.
func hostTestSnapshot(
    registry: HostSnapshotRegistry,
    session: String,
    window: HostWindowInfo = hostTestWindow(),
    capturedAt: Int64 = hostNowMs(),
    imagePath: String? = nil,
    image: HostImageReference? = nil,
    enabled: Bool = true,
    elementFrame: HostRect? = nil,
    element: AXUIElement? = nil
) -> HostSnapshot {
    let id = registry.nextSnapshotId()
    let binding = hostTestBinding(
        token: "el_\(id)_0",
        digestInput: HostElementDigestInput(role: "AXButton", label: "Send"),
        enabled: enabled,
        frame: elementFrame,
        element: element
    )

    let windowDigest = hostWindowDigest(
        elementDigests: [binding.digest],
        bounds: window.bounds,
        title: window.title
    )

    let payload = HostSnapshotPayload(
        snapshotId: id,
        capturedAt: capturedAt,
        target: HostWindowTarget(
            pid: window.pid,
            windowId: window.windowId,
            appId: window.appId,
            appName: window.appName,
            title: window.title,
            bounds: HostRect(window.bounds),
            layer: window.layer,
            zIndex: window.zIndex,
            displayId: window.displayId
        ),
        windowDigest: windowDigest,
        focusedElementToken: nil,
        selectedText: nil,
        image: image,
        displays: [],
        obscuringRects: [],
        elements: [binding.observed],
        truncated: HostSnapshotTruncation(elements: false, depth: false)
    )

    return HostSnapshot(
        id: id,
        session: session,
        pid: window.pid,
        windowId: window.windowId,
        capturedAt: capturedAt,
        windowDigest: windowDigest,
        payload: payload,
        bindings: [binding],
        imagePath: imagePath
    )
}

func hostTestImage(scale: Double = 2.0) -> HostImageReference {
    HostImageReference(
        path: "/tmp/maka-cu-tests/snap.png",
        format: .png,
        widthPx: Int(hostTestWindowBounds.width * scale),
        heightPx: Int(hostTestWindowBounds.height * scale),
        byteLength: 1,
        sha256: "sha256:" + String(repeating: "0", count: 64),
        scale: scale
    )
}

// MARK: - Server harness

/// Drives `HostProtocolServer.handle(line:)` and collects whole response lines.
/// The lanes are real serial queues, so responses are awaited rather than read.
final class ServerHarness {
    let server: HostProtocolServer
    let environment: FakeEnvironment
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

    init(environment: FakeEnvironment = FakeEnvironment()) {
        imageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("maka-cu-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)

        let inbox = LineInbox()
        self.inbox = inbox
        self.environment = environment
        server = HostProtocolServer(
            output: HostOutputWriter { inbox.append($0) },
            environment: environment
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: imageDirectory)
    }

    func send(_ line: String) {
        server.handle(line: line)
    }

    func sendHello(protocolVersion: String = makaCuProtocolVersion, imageDir: String? = nil) {
        let directory = imageDir ?? imageDirectory.path
        send("""
        {"jsonrpc":"2.0","id":1,"method":"host.hello","params":{"protocol":"\(protocolVersion)","hostPid":\(ProcessInfo.processInfo.processIdentifier),"imageDir":"\(directory)","allowGlobalPointer":false}}
        """)
    }

    /// Handshake, one session, and a snapshot registered directly — a snapshot
    /// minted through `observe` would need a live Accessibility tree, and the
    /// dispatch rules under test all run before the element is touched.
    @discardableResult
    func begin(session: String = "s1", captureScope: String = "window") throws -> [String: Any] {
        sendHello()
        _ = try awaitResponse()
        send(#"{"jsonrpc":"2.0","id":2,"method":"session.begin","params":{"session":"\#(session)","captureScope":"\#(captureScope)"}}"#)
        return try awaitResponse()
    }

    func install(_ snapshot: HostSnapshot) {
        server.currentRegistry().register(snapshot)
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

    /// The `result` object of the next response, which is where every domain
    /// outcome lives — §1.1 keeps JSON-RPC `error` for unusable requests only.
    func awaitResult(timeout: TimeInterval = 2) throws -> [String: Any] {
        let response = try awaitResponse(timeout: timeout)
        XCTAssertNil(response["error"], "a domain outcome is never a JSON-RPC error")
        return try XCTUnwrap(response["result"] as? [String: Any])
    }
}

struct HostHarnessTimeout: Error {}
