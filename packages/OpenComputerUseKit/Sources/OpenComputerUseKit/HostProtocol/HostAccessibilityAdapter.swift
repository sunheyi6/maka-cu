import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

/// Everything in this file talks to macOS. It is kept apart from the protocol
/// logic so the lifecycle, binding and path rules stay testable without a
/// desktop, and so this is the only place to look when Accessibility behaviour
/// changes underneath us.

// MARK: - Process identity (E2)

/// §4.3 E2 — a recycled pid must fail. `p_starttime` is the only field that
/// distinguishes "same process" from "same number".
public func hostProcessStartTime(pid: pid_t) -> UInt64? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    let read = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
    guard read == size else {
        return nil
    }

    return UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec)
}

// MARK: - Window inventory

public struct HostWindowInfo: Equatable, Sendable {
    public let pid: pid_t
    public let windowId: CGWindowID
    /// §5.1 — the one namespace. `appName` beside it is a display string and is
    /// never matched against; its absence here is what made an app string
    /// unresolvable against this list.
    public let appId: String
    public let appName: String
    public let title: String?
    public let bounds: CGRect
    public let layer: Int
    public let zIndex: Int
    public let onScreen: Bool
    public let displayId: String?
}

public enum HostWindowInventory {
    /// Front-to-back. `zIndex` counts down from the window count so it is
    /// strictly decreasing and never ties — the host resolves occlusion with it.
    public static func onScreenWindows() -> [HostWindowInfo] {
        guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let total = infoList.count
        return infoList.enumerated().compactMap { offset, info in
            guard
                let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                let number = info[kCGWindowNumber as String] as? NSNumber,
                let layer = info[kCGWindowLayer as String] as? Int,
                let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary)
            else {
                return nil
            }

            let title = info[kCGWindowName as String] as? String
            return HostWindowInfo(
                pid: pid,
                windowId: CGWindowID(number.uint32Value),
                appId: hostAppId(
                    bundleIdentifier: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
                    pid: pid
                ),
                appName: info[kCGWindowOwnerName as String] as? String ?? "",
                title: (title?.isEmpty ?? true) ? nil : title,
                bounds: bounds,
                layer: layer,
                zIndex: total - offset,
                onScreen: true,
                displayId: displayId(containing: bounds)
            )
        }
    }

    /// §5 — the layer-0 windows stacked above the target, in screen points.
    ///
    /// The titleless full-screen Dock surface is excluded here rather than in the
    /// host: it covers every display at layer 0 and would mark every window as
    /// obscured. The host filters it by hand today, and the filter belongs on the
    /// side that reads the window list.
    public static func obscuringRects(above target: HostWindowInfo, in windows: [HostWindowInfo]) -> [CGRect] {
        windows
            .filter { $0.layer == 0 && $0.zIndex > target.zIndex && $0.windowId != target.windowId }
            .filter { !isFullScreenDockSurface($0) }
            .filter { $0.bounds.intersects(target.bounds) }
            .map(\.bounds)
    }

    static func isFullScreenDockSurface(_ window: HostWindowInfo) -> Bool {
        guard window.appName == "Dock", window.title == nil else {
            return false
        }

        return NSScreen.screens.contains { screen in
            window.bounds.width >= screen.frame.width && window.bounds.height >= screen.frame.height
        }
    }

    static func displayId(containing bounds: CGRect) -> String? {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }

            if CGDisplayBounds(CGDirectDisplayID(number.uint32Value)).contains(center) {
                return String(number.uint32Value)
            }
        }

        return nil
    }

    public static func displays() -> [HostDisplayInfo] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }

            let displayId = CGDirectDisplayID(number.uint32Value)
            let logical = CGDisplayBounds(displayId)
            let scale = Double(screen.backingScaleFactor)
            return HostDisplayInfo(
                displayId: String(number.uint32Value),
                logicalBounds: HostRect(logical),
                sourceBoundsPx: HostRect(
                    x: 0,
                    y: 0,
                    width: Double(CGDisplayPixelsWide(displayId)) * scale,
                    height: Double(CGDisplayPixelsHigh(displayId)) * scale
                ),
                scaleFactor: scale
            )
        }
    }
}

/// The displays attached right now, asked of the window server rather than read
/// off `NSScreen.screens`. §5.5 — AppKit's caches are refreshed by the main run
/// loop, and this executor's main thread sits in `readLine`; a lane that asks
/// `NSScreen` whether a display exists can be answered from a snapshot taken
/// before the display was plugged in. `screen.capture` validates the caller's
/// `displayId` against this, so the answer has to come from the machine.
public func hostActiveDisplayIds() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
        return []
    }

    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
        return []
    }

    return Array(ids.prefix(Int(count)))
}

/// `CGSessionCopyCurrentDictionary` is the only reliable lock signal available to
/// a background process: Accessibility and ScreenCaptureKit both fail on a locked
/// screen, but they fail with codes that also mean other things.
public func hostScreenIsLocked() -> Bool {
    guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
        return false
    }

    return session["CGSSessionScreenIsLocked"] as? Bool == true
}

// MARK: - Accessibility node adapter

/// Wraps one `AXUIElement` as a `HostAccessibilityNode`. The wrapper holds the
/// element, which is what keeps the reference alive for the snapshot's lifetime.
final class HostAXNode: HostAccessibilityNode {
    let element: AXUIElement
    private let windowBounds: CGRect
    private let focusedElement: AXUIElement?

    init(element: AXUIElement, windowBounds: CGRect, focusedElement: AXUIElement?) {
        self.element = element
        self.windowBounds = windowBounds
        self.focusedElement = focusedElement
    }

    var axElement: AXUIElement? { element }

    var role: String {
        HostAX.string(element, kAXRoleAttribute) ?? "AXUnknown"
    }

    var subrole: String? {
        HostAX.string(element, kAXSubroleAttribute)
    }

    var axIdentifier: String? {
        HostAX.string(element, kAXIdentifierAttribute)
    }

    var title: String? {
        HostAX.string(element, kAXTitleAttribute)
    }

    var label: String? {
        HostAX.string(element, kAXDescriptionAttribute)
    }

    var value: String? {
        HostAX.stringLikeValue(element, kAXValueAttribute)
    }

    var placeholder: String? {
        HostAX.string(element, "AXPlaceholderValue")
    }

    var enabled: Bool {
        HostAX.bool(element, kAXEnabledAttribute) ?? true
    }

    var focused: Bool {
        guard let focusedElement else {
            return HostAX.bool(element, kAXFocusedAttribute) ?? false
        }

        return CFEqual(focusedElement, element)
    }

    var selected: Bool? {
        HostAX.bool(element, kAXSelectedAttribute)
    }

    var frameInWindow: CGRect? {
        guard let frame = HostAX.frame(element) else {
            return nil
        }

        return windowRelativeFrame(elementFrame: frame, windowBounds: windowBounds)
    }

    var rawActionNames: [String] {
        HostAX.actionNames(element)
    }

    var children: [HostAccessibilityNode] {
        HostAX.children(of: element).map {
            HostAXNode(element: $0, windowBounds: windowBounds, focusedElement: focusedElement)
        }
    }
}

enum HostAX {
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        guard let value = attribute(element, name) as? String, !value.isEmpty else {
            return nil
        }
        return value
    }

    /// Values come back as strings, numbers or booleans depending on the role.
    /// The digest is over the string form, so the conversion has to be stable.
    static func stringLikeValue(_ element: AXUIElement, _ name: String) -> String? {
        guard let value = attribute(element, name) else {
            return nil
        }

        if let text = value as? String {
            return text.isEmpty ? nil : text
        }

        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return (value as? NSNumber)?.boolValue == true ? "true" : "false"
        }

        if let number = value as? NSNumber {
            return number.stringValue
        }

        return nil
    }

    static func bool(_ element: AXUIElement, _ name: String) -> Bool? {
        guard let value = attribute(element, name) else {
            return nil
        }

        return (value as? NSNumber)?.boolValue
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard
            let positionValue = attribute(element, kAXPositionAttribute),
            let sizeValue = attribute(element, kAXSizeAttribute)
        else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard
            AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    static func actionNames(_ element: AXUIElement) -> [String] {
        var actions: CFArray?
        guard AXUIElementCopyActionNames(element, &actions) == .success else {
            return []
        }
        return actions as? [String] ?? []
    }

    static func children(of element: AXUIElement) -> [AXUIElement] {
        let role = string(element, kAXRoleAttribute)
        let rows = array(element, kAXRowsAttribute)
        let visible = array(element, "AXVisibleChildren")
        let attributes = childTraversalAttributes(
            role: role,
            hasRows: !rows.isEmpty,
            hasVisibleChildren: !visible.isEmpty
        )

        var result: [AXUIElement] = []
        for attribute in attributes {
            let values: [AXUIElement]
            switch attribute {
            case kAXRowsAttribute:
                values = rows
            case "AXVisibleChildren":
                values = visible
            default:
                values = array(element, attribute)
            }

            for child in values where !result.contains(where: { CFEqual($0, child) }) {
                result.append(child)
            }
        }

        return result
    }

    static func array(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
        guard let value = attribute(element, name) else {
            return []
        }
        return value as? [AXUIElement] ?? []
    }

    /// §4.3 E1 — alive means an attribute read answers with something other than
    /// `kAXErrorInvalidUIElement`. A failure for any other reason (a busy app, an
    /// unsupported attribute) is not evidence that the element is gone.
    static func isAlive(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
        return result != .invalidUIElement
    }

    static func pid(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else {
            return nil
        }
        return pid
    }

    static func window(pid: pid_t, windowId: CGWindowID, bounds: CGRect) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)

        // Ask first; only reach for the switches if the app really is holding
        // its tree back.
        //
        // `AXEnhancedUserInterface` is the flag VoiceOver sets. Setting it puts
        // an app into a different accessibility mode, it is process-wide, and
        // there is no way to put it back — AppKit apps have shipped bugs under
        // it for years, from slow window resizing to windows that stop
        // reporting at all. This used to be set on *every* app on *every*
        // observation, including the great majority that expose their tree
        // without being asked, which means a read quietly and permanently
        // changed the thing it was reading.
        //
        // Chromium and Electron genuinely need it: they withhold the tree until
        // something asks. So the rule is ask-then-set, not set-then-ask, and an
        // app that already answers is left exactly as it was found.
        var windows = array(application, kAXWindowsAttribute)
        if windows.isEmpty {
            _ = AXUIElementSetAttributeValue(
                application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            _ = AXUIElementSetAttributeValue(
                application, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            windows = array(application, kAXWindowsAttribute)
        }

        // There is no public AX attribute carrying a CGWindowID, so the window is
        // matched by its frame against the one the window list reported. Bounds
        // are compared at whole-point resolution because AX and CGWindowList
        // disagree in the sub-pixel digits on scaled displays.
        let matchesReportedFrame = { (candidate: AXUIElement) -> Bool in
            guard let frame = frame(candidate) else {
                return false
            }
            return abs(frame.origin.x - bounds.origin.x) < 1
                && abs(frame.origin.y - bounds.origin.y) < 1
                && abs(frame.width - bounds.width) < 1
                && abs(frame.height - bounds.height) < 1
        }

        if let matched = windows.first(where: matchesReportedFrame) {
            return matched
        }

        // A sheet is a window to CGWindowList and a child to accessibility. It
        // is never in `AXWindows` — it is a child of its parent window whose
        // role is `AXSheet`, and a drawer is the same shape. Alerts, save
        // panels, print panels and permission prompts are all sheets, so an
        // observer that reads only `AXWindows` goes blind exactly when the app
        // has stopped to ask a question — and `{ "kind": "app" }` resolves to
        // the frontmost window, which while a sheet is up is the sheet.
        //
        // There is no `AXSheets` attribute, which is the trap. AppleScript
        // offers `sheets of window` and that reads like one, but System Events
        // synthesises it by filtering `AXChildren` on role; asking accessibility
        // for "AXSheets" returns an empty list, silently, on a window that
        // plainly has a sheet. Measured against the CUA Lab fixture with its
        // modal open: CGWindowList reported two windows, `AXWindows` reported
        // one, "AXSheets" reported zero, and `AXChildren` had the `AXSheet`
        // sitting in it at exactly the frame the window list had named.
        for window in windows {
            for child in array(window, kAXChildrenAttribute)
            where sheetLikeRoles.contains(string(child, kAXRoleAttribute) ?? "")
                && matchesReportedFrame(child) {
                return child
            }
        }

        return nil
    }

    /// Roles that CGWindowList reports as a window of their own while
    /// accessibility reports them as a child of one.
    static let sheetLikeRoles: Set<String> = ["AXSheet", "AXDrawer"]

    static func focusedElement(pid: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        guard let value = attribute(application, kAXFocusedUIElementAttribute) else {
            return nil
        }
        return (value as! AXUIElement)
    }

    static func selectedText(_ element: AXUIElement) -> String? {
        string(element, kAXSelectedTextAttribute)
    }

    static func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var settable: DarwinBoolean = false
        let result = AXUIElementIsAttributeSettable(element, name as CFString, &settable)
        return result == .success && settable.boolValue
    }

    static func parent(of element: AXUIElement) -> AXUIElement? {
        guard let value = attribute(element, kAXParentAttribute) else {
            return nil
        }
        return (value as! AXUIElement)
    }

    /// Recomputes the §4.3 ancestor roles from live parent links. The walk stops
    /// once it has appended the window role, because the tree walk that recorded
    /// the digest was rooted at the window and would never have seen the
    /// application element above it.
    static func ancestorRoles(of element: AXUIElement) -> [String] {
        var roles: [String] = []
        var current = element

        while roles.count < 8, let parent = parent(of: current) {
            let role = string(parent, kAXRoleAttribute) ?? "AXUnknown"
            roles.append(role)
            if role == kAXWindowRole as String {
                break
            }
            current = parent
        }

        return roles
    }

    /// The element's position among its parent's traversed children, computed
    /// through the same traversal used at observe time so the two cannot disagree.
    static func siblingIndex(of element: AXUIElement) -> Int {
        guard let parent = parent(of: element) else {
            return 0
        }

        return children(of: parent).firstIndex(where: { CFEqual($0, element) }) ?? 0
    }
}

/// The binding probe backed by live Accessibility. Mirrors `hostWalkTree`'s digest
/// inputs exactly; if the two ever drift, every dispatch fails `element_changed`.
struct HostAXBindingProbe: HostElementBindingProbe {
    let windowBounds: CGRect

    func isReferenceAlive(_ binding: HostElementBinding) -> Bool {
        guard let element = binding.element else {
            return false
        }
        return HostAX.isAlive(element)
    }

    func processStartTime(pid: pid_t) -> UInt64? {
        hostProcessStartTime(pid: pid)
    }

    func currentDigestInput(_ binding: HostElementBinding) -> HostElementDigestInput? {
        guard let element = binding.element else {
            return nil
        }

        let node = HostAXNode(element: element, windowBounds: windowBounds, focusedElement: nil)
        let actions = node.rawActionNames
            .compactMap(HostElementActionName.normalized(rawAXAction:))
            .reduce(into: [HostElementActionName]()) { unique, action in
                if !unique.contains(action) {
                    unique.append(action)
                }
            }

        return HostElementDigestInput(
            role: node.role,
            subrole: node.subrole,
            axIdentifier: node.axIdentifier,
            title: node.title,
            label: node.label,
            untruncatedValue: node.value,
            frameInWindow: node.frameInWindow,
            actionNames: actions.map(\.rawValue),
            // The snapshot is rooted at the window, so the root element has no
            // ancestors and no siblings *inside the snapshot*. Reading them from
            // the application element above it would fail E3 on every dispatch
            // that targets the window itself.
            ancestorRoles: binding.depth == 0 ? [] : HostAX.ancestorRoles(of: element),
            siblingIndex: binding.depth == 0 ? 0 : HostAX.siblingIndex(of: element)
        )
    }
}
