import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Everything the protocol handlers need to know about the live machine, behind
/// one seam.
///
/// It exists because the binding rules of §4 were unreachable from a test: every
/// dispatch handler read the window list, the permission state and the
/// Accessibility tree through file-scope statics, so deleting the digest
/// comparison, the binding probe or the occlusion gate left the whole suite
/// green. The live implementation below is the production path; the handlers name
/// nothing else.

/// §5.5 — one running application. `appId` is the §5.1 namespace; `name` is the
/// display string and is never matched against.
public struct HostRunningApp: Equatable, Sendable {
    public let appId: String
    public let pid: pid_t
    public let name: String
    public let running: Bool

    public init(appId: String, pid: pid_t, name: String, running: Bool) {
        self.appId = appId
        self.pid = pid
        self.name = name
        self.running = running
    }
}

public protocol HostSystemEnvironment {
    func screenIsLocked() -> Bool
    func permissions() -> PermissionDiagnostics
    func runningApps() -> [HostRunningApp]
    /// §5.7 — `apps.launch`. Resolves the request to a running application,
    /// starting it if it is not running yet, and gives up after `budget`.
    ///
    /// It is behind the seam for the reason the rest of this protocol is: the
    /// failure arms — nothing on disk, started but too slow, refused by the
    /// safety list — are otherwise only reachable by launching real
    /// applications on the machine running the tests.
    func launchApp(_ query: String, waitFor budget: TimeInterval) -> Result<HostRunningApp, HostDomainError>
    /// Front-to-back, as §5.4 requires.
    func onScreenWindows() -> [HostWindowInfo]
    func windowElement(pid: pid_t, windowId: CGWindowID, bounds: CGRect) -> AXUIElement?
    func focusedElement(pid: pid_t) -> AXUIElement?
    /// §6.4 — `focusPolicy: "acquire"`. Writes `kAXFocusedAttribute` and answers
    /// whether the write itself was accepted. It is not proof that focus moved:
    /// an application may return success and leave focus where it was, so the
    /// caller re-reads `focusedElement(pid:)` before posting anything.
    func setFocusedElement(_ element: AXUIElement, pid: pid_t) -> Bool
    func bindingProbe(windowBounds: CGRect) -> HostElementBindingProbe
    /// §6.3 — the path has already been selected and permitted by
    /// `hostPointDispatchPath`; this only posts it.
    func postPointEvent(
        _ action: HostPointAction,
        at point: CGPoint,
        from start: CGPoint?,
        pid: pid_t,
        path: HostDispatchPath
    ) throws
    /// §6.4 — posted to the target pid. Behind the same seam as the pointer for
    /// the same reason: a handler that reaches the keyboard directly cannot be
    /// asserted against without typing into whatever process holds that pid.
    func postKeyEvent(_ action: HostKeyAction, pid: pid_t) throws
}

public struct HostLiveEnvironment: HostSystemEnvironment {
    public init() {}

    public func screenIsLocked() -> Bool {
        hostScreenIsLocked()
    }

    public func permissions() -> PermissionDiagnostics {
        PermissionDiagnostics.current()
    }

    public func runningApps() -> [HostRunningApp] {
        AppDiscovery.runningApps().map { app in
            HostRunningApp(
                appId: hostAppId(bundleIdentifier: app.bundleIdentifier, pid: app.pid),
                pid: app.pid,
                name: app.name,
                running: !app.runningApplication.isTerminated
            )
        }
    }

    public func launchApp(_ query: String, waitFor budget: TimeInterval) -> Result<HostRunningApp, HostDomainError> {
        do {
            let app = try AppDiscovery.resolve(query, waitFor: budget)
            return .success(
                HostRunningApp(
                    appId: hostAppId(bundleIdentifier: app.bundleIdentifier, pid: app.pid),
                    pid: app.pid,
                    name: app.name,
                    running: !app.runningApplication.isTerminated
                )
            )
        } catch {
            return .failure(hostAppLaunchFailure(error))
        }
    }

    public func onScreenWindows() -> [HostWindowInfo] {
        HostWindowInventory.onScreenWindows()
    }

    public func windowElement(pid: pid_t, windowId: CGWindowID, bounds: CGRect) -> AXUIElement? {
        HostAX.window(pid: pid, windowId: windowId, bounds: bounds)
    }

    public func focusedElement(pid: pid_t) -> AXUIElement? {
        HostAX.focusedElement(pid: pid)
    }

    public func setFocusedElement(_ element: AXUIElement, pid: pid_t) -> Bool {
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    }

    public func bindingProbe(windowBounds: CGRect) -> HostElementBindingProbe {
        HostAXBindingProbe(windowBounds: windowBounds)
    }

    public func postPointEvent(
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

    public func postKeyEvent(_ action: HostKeyAction, pid: pid_t) throws {
        // Key events are posted to the target pid. The executor never activates
        // the application, raises its window, or changes the frontmost app.
        switch action {
        case .type(let text):
            try InputSimulation.typeText(text, pid: pid)
        case .key(let name, let modifiers):
            try InputSimulation.pressKey(
                hostKeySpecification(name: name, modifiers: modifiers),
                pid: pid,
                extraFlags: modifiers.contains(.fn) ? .maskSecondaryFn : []
            )
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
}

// MARK: - Failing a launch (§5.7)

/// The ways `apps.launch` fails are different things, and the caller acts on
/// them differently. Collapsing them — which the handler used to do with a
/// `try?` that answered `app_not_found` to everything — told the model to try
/// another name in three cases where another name cannot help: the app was
/// still starting, the app is on the safety list, or the launch itself was
/// refused by the system.
public func hostAppLaunchFailure(_ error: Error) -> HostDomainError {
    guard let error = error as? ComputerUseError else {
        // `NSWorkspace.openApplication` said no. It was attempted and it did not
        // happen, which is what `dispatch_refused` means; the app is not missing.
        return HostDomainError(.dispatchRefused)
    }

    switch error {
    case .appNotFound:
        return HostDomainError(.appNotFound)
    case .timeout:
        return HostDomainError(.timeout)
    case .permissionDenied:
        // Not `permission_missing`: no macOS grant would change this answer. The
        // executor will not drive this application at all, so naming it again,
        // or granting something, is not the way forward.
        return HostDomainError(.unsupportedAction)
    case .message, .unsupportedTool, .invalidArguments, .stateUnavailable:
        return HostDomainError(.dispatchRefused)
    }
}

// MARK: - Resolving `{ "kind": "app" }`

/// §5.1 / §5.2 — the executor resolves an `appId` by exact string match, against
/// applications that are **already running**, and refuses everything else.
///
/// Two rules are load-bearing and neither is defensive:
///
/// - No launch. `observe` is a read. The previous implementation went through
///   `AppDiscovery.resolve`, which falls through to `NSWorkspace.openApplication`
///   with a configuration that activates, and then polls for five seconds — so
///   observing a not-running app started it and took the user's foreground, with
///   nothing on the wire saying so. `apps.launch` is the method that launches.
/// - No fallback to `appName` or `title`. Those are display strings (§1.2): they
///   are localised, two apps may share one, and matching them is how a caller's
///   `app` silently addressed a different process.
public func hostResolveAppTarget(
    appId: String,
    in apps: [HostRunningApp]
) -> Result<HostRunningApp, HostDomainError> {
    guard let match = apps.first(where: { $0.appId == appId }) else {
        return .failure(HostDomainError(.appNotFound))
    }

    return .success(match)
}
