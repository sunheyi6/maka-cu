import ApplicationServices
import CoreGraphics
import CryptoKit
import Foundation

/// §4.3 — the inputs to an element digest, recorded at observe time and
/// recomputed at dispatch time.
///
/// `valueDigest` is deliberately taken over the *untruncated* value: the wire
/// value is capped at `limits.maxTextChars`, and digesting the capped copy would
/// make every edit past character 500 invisible to the binding check.
public struct HostElementDigestInput: Equatable, Sendable {
    public var role: String
    public var subrole: String?
    public var axIdentifier: String?
    public var title: String?
    public var label: String?
    public var valueDigest: String?
    public var frameInWindow: CGRect?
    public var sortedActionNames: [String]
    /// Root-ward, capped at 8 levels. §4.3.
    public var ancestorRoles: [String]
    public var siblingIndex: Int

    public init(
        role: String,
        subrole: String? = nil,
        axIdentifier: String? = nil,
        title: String? = nil,
        label: String? = nil,
        untruncatedValue: String? = nil,
        frameInWindow: CGRect? = nil,
        actionNames: [String] = [],
        ancestorRoles: [String] = [],
        siblingIndex: Int = 0
    ) {
        self.role = role
        self.subrole = subrole
        self.axIdentifier = axIdentifier
        self.title = title
        self.label = label
        self.valueDigest = untruncatedValue.map { HostDigest.sha256(Data($0.utf8)) }
        self.frameInWindow = frameInWindow
        self.sortedActionNames = actionNames.sorted()
        self.ancestorRoles = Array(ancestorRoles.prefix(8))
        self.siblingIndex = siblingIndex
    }
}

/// §5 — the raw AX action names mapped onto the closed set, deduplicated, in the
/// order the application reported them. Shared because the digest is taken over
/// this list and the wire carries it, and the two must be the same list.
public func hostNormalizedActions(_ rawAXActions: [String]) -> [HostElementActionName] {
    rawAXActions
        .compactMap(HostElementActionName.normalized(rawAXAction:))
        .reduce(into: [HostElementActionName]()) { unique, action in
            if !unique.contains(action) {
                unique.append(action)
            }
        }
}

/// §4.3 — one node's digest inputs, assembled the one way.
///
/// Both ends of the binding check come through here: `hostWalkTree` records what
/// this returns, and `HostAXBindingProbe` recomputes it at dispatch. They used to
/// assemble the field list separately, which is a second copy of §4.3 — and the
/// copies have now drifted twice, each time refusing a dispatch against something
/// nothing had touched:
///
/// - `ancestorRoles` taken from the walker's own traversal on one side and from
///   `AXParent` on the other, which disagree on every Chromium tree.
/// - `ancestorRoles` for the **root**: the walker read the live chain for every
///   node, so a window recorded `["AXApplication"]`, while the probe answered
///   `[]`. One element out of sixty-five, and no element dispatch could see it —
///   it checks the element it targets. `dispatch.point` has no element to target,
///   anchors on the whole window, and so refused `window_changed` on every call
///   against every application.
///
/// `depth == 0` is the snapshot's root, and inside the frame the root has no
/// ancestors and no siblings: the walk is rooted at the window and never sees the
/// application element above it. Both halves of that rule are applied here so
/// neither caller can hold half of it — which is the shape of the second drift.
/// Emptiness is also the stabler reading: an application's `AXWindows` is ordered
/// by z-order in many apps, so a root that took its identity from its live
/// position would change it whenever a *different* window of the same app came
/// forward.
///
/// `actions` is passed in rather than read from the node because the observation
/// needs the same list for the wire, and `rawActionNames` is an Accessibility
/// round trip — reading it once here and once there doubles a per-element IPC on
/// the walk. The ancestor chain and the sibling index are autoclosures for the
/// same reason: the root needs neither, and each is another round trip.
public func hostElementDigestInput(
    node: HostAccessibilityNode,
    depth: Int,
    actions: [HostElementActionName],
    ancestorRoles: @autoclosure () -> [String],
    siblingIndex: @autoclosure () -> Int
) -> HostElementDigestInput {
    let isRoot = depth == 0
    return HostElementDigestInput(
        role: node.role,
        subrole: node.subrole,
        axIdentifier: node.axIdentifier,
        title: node.title,
        label: node.label,
        untruncatedValue: node.value,
        frameInWindow: node.frameInWindow,
        actionNames: actions.map(\.rawValue),
        ancestorRoles: isRoot ? [] : ancestorRoles(),
        siblingIndex: isRoot ? 0 : siblingIndex()
    )
}

public enum HostDigest {
    public static func sha256(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Canonical JSON array over the §4.3 field order. Serialised by hand rather
    /// than through `JSONSerialization` because the digest must be stable across
    /// Foundation versions and must not depend on dictionary key ordering.
    static func canonicalArray(_ parts: [String]) -> Data {
        Data(("[" + parts.joined(separator: ",") + "]").utf8)
    }

    static func canonicalString(_ value: String?) -> String {
        guard let value else {
            return "null"
        }

        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"":
                escaped += "\\\""
            case "\\":
                escaped += "\\\\"
            case "\n":
                escaped += "\\n"
            case "\r":
                escaped += "\\r"
            case "\t":
                escaped += "\\t"
            default:
                if scalar.value < 0x20 {
                    escaped += String(format: "\\u%04x", scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }

        return "\"" + escaped + "\""
    }

    static func canonicalNumber(_ value: Double) -> String {
        // Frames arrive as CGFloat points; rounding to a whole point keeps the
        // digest from flickering on sub-pixel layout noise while still catching
        // any move a user could see.
        String(Int(value.rounded()))
    }

    static func canonicalRect(_ rect: CGRect?) -> String {
        guard let rect else {
            return "null"
        }

        return "["
            + canonicalNumber(Double(rect.origin.x)) + ","
            + canonicalNumber(Double(rect.origin.y)) + ","
            + canonicalNumber(Double(rect.size.width)) + ","
            + canonicalNumber(Double(rect.size.height))
            + "]"
    }

    static func canonicalStringArray(_ values: [String]) -> String {
        "[" + values.map(canonicalString).joined(separator: ",") + "]"
    }
}

public func hostElementDigest(_ input: HostElementDigestInput) -> String {
    let parts = [
        HostDigest.canonicalString(input.role),
        HostDigest.canonicalString(input.subrole),
        HostDigest.canonicalString(input.axIdentifier),
        HostDigest.canonicalString(input.title),
        HostDigest.canonicalString(input.label),
        HostDigest.canonicalString(input.valueDigest),
        HostDigest.canonicalRect(input.frameInWindow),
        HostDigest.canonicalStringArray(input.sortedActionNames),
        HostDigest.canonicalStringArray(input.ancestorRoles),
        String(input.siblingIndex),
    ]

    return HostDigest.sha256(HostDigest.canonicalArray(parts))
}

/// §4.3 — the window digest is the anchor for point dispatch, which has no
/// element to bind to.
public func hostWindowDigest(
    elementDigests: [String],
    bounds: CGRect?,
    title: String?
) -> String {
    let parts = [
        HostDigest.canonicalStringArray(elementDigests.sorted()),
        HostDigest.canonicalRect(bounds),
        HostDigest.canonicalString(title),
    ]

    return HostDigest.sha256(HostDigest.canonicalArray(parts))
}

/// §6.2 — `detail.changed` exists so a host log can say *why* without parsing prose.
public func hostChangedDigestFields(
    recorded: HostElementDigestInput,
    current: HostElementDigestInput
) -> [HostElementDigestField] {
    var changed: [HostElementDigestField] = []

    if recorded.role != current.role {
        changed.append(.role)
    }
    if recorded.subrole != current.subrole {
        changed.append(.subrole)
    }
    if recorded.axIdentifier != current.axIdentifier {
        changed.append(.axIdentifier)
    }
    if recorded.title != current.title {
        changed.append(.title)
    }
    if recorded.label != current.label {
        changed.append(.label)
    }
    if recorded.valueDigest != current.valueDigest {
        changed.append(.value)
    }
    if HostDigest.canonicalRect(recorded.frameInWindow) != HostDigest.canonicalRect(current.frameInWindow) {
        changed.append(.frame)
    }
    if recorded.sortedActionNames != current.sortedActionNames {
        changed.append(.actions)
    }
    if recorded.ancestorRoles != current.ancestorRoles {
        changed.append(.ancestors)
    }
    if recorded.siblingIndex != current.siblingIndex {
        changed.append(.siblingIndex)
    }

    return changed
}

// MARK: - Binding checks

/// The three checks of §4.3, factored away from Accessibility so they can be
/// exercised without a live desktop.
public protocol HostElementBindingProbe {
    /// E1 — an attribute read answers with something other than
    /// `kAXErrorInvalidUIElement`.
    func isReferenceAlive(_ binding: HostElementBinding) -> Bool
    /// E2 — the recorded pid still exists with the recorded start time.
    func processStartTime(pid: pid_t) -> UInt64?
    /// E3 — the digest inputs as they are right now, or `nil` when the element
    /// can no longer be read at all.
    func currentDigestInput(_ binding: HostElementBinding) -> HostElementDigestInput?
}

/// One element of one snapshot, with everything the binding check needs.
public final class HostElementBinding {
    public let token: String
    public let parentToken: String?
    public let depth: Int
    public let pid: pid_t
    public let processStartTime: UInt64
    public let digestInput: HostElementDigestInput
    public let digest: String
    /// Retained for the life of the snapshot. `nil` only in tests and fixtures.
    public let element: AXUIElement?
    public let observed: HostObservedElement

    public init(
        token: String,
        parentToken: String?,
        depth: Int,
        pid: pid_t,
        processStartTime: UInt64,
        digestInput: HostElementDigestInput,
        element: AXUIElement?,
        observed: HostObservedElement
    ) {
        self.token = token
        self.parentToken = parentToken
        self.depth = depth
        self.pid = pid
        self.processStartTime = processStartTime
        self.digestInput = digestInput
        self.digest = hostElementDigest(digestInput)
        self.element = element
        self.observed = observed
    }
}

/// Verifies E1, E2 and E3 in that order. The order matters: a dead reference and
/// a recycled pid are different diagnoses, and reporting a digest mismatch for a
/// process that no longer exists would send the host down the wrong retry path.
public func hostVerifyBinding(
    _ binding: HostElementBinding,
    probe: HostElementBindingProbe
) -> HostDomainError? {
    guard probe.isReferenceAlive(binding) else {
        return HostDomainError(.elementReleased)
    }

    guard let startTime = probe.processStartTime(pid: binding.pid), startTime == binding.processStartTime else {
        return HostDomainError(.processReplaced)
    }

    guard let current = probe.currentDigestInput(binding) else {
        return HostDomainError(.elementReleased)
    }

    let changed = hostChangedDigestFields(recorded: binding.digestInput, current: current)
    guard changed.isEmpty else {
        return HostDomainError(.elementChanged, detail: .changed(changed))
    }

    return nil
}
