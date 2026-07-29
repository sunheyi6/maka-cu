import ApplicationServices
import CoreGraphics
import Foundation

/// §5 — the observation payload. Structured data only: no rendered tree, no
/// catalogue text, nothing the model reads as prose. Maka's runtime owns every
/// model-facing word.

public struct HostObservedElement: Codable, Equatable, Sendable {
    public let token: String
    public let parentToken: String?
    public let depth: Int
    public let role: String
    public let subrole: String?
    public let axIdentifier: String?
    public let label: String?
    public let value: String?
    public let placeholder: String?
    public let enabled: Bool
    public let focused: Bool
    public let selected: Bool?
    /// Window-local logical points, origin at the window's top-left. §5.
    public let frame: HostRect?
    public let actions: [HostElementActionName]
    public let digest: String
    /// Which of this element's text fields were cut at `maxTextChars`. Empty is
    /// emitted, never omitted, so "was anything cut" is a field read.
    public let truncated: [HostElementTextField]
}

public enum HostElementTextField: String, Codable, Equatable, Sendable {
    case label
    case value
    case placeholder
}

public struct HostSelectedText: Codable, Equatable, Sendable {
    public let text: String
    public let truncated: Bool
}

public struct HostImageReference: Codable, Equatable, Sendable {
    public let path: String
    public let format: HostImageFormat
    public let widthPx: Int
    public let heightPx: Int
    public let byteLength: Int
    public let sha256: String
    /// §5 — measured as `widthPx / target.bounds.width` from the image actually
    /// captured, never read off `NSScreen.backingScaleFactor`.
    public let scale: Double
}

public struct HostDisplayInfo: Codable, Equatable, Sendable {
    public let displayId: String
    public let logicalBounds: HostRect
    public let sourceBoundsPx: HostRect
    public let scaleFactor: Double
}

public struct HostWindowTarget: Codable, Equatable, Sendable {
    public let pid: Int32
    public let windowId: UInt32
    public let bundleId: String?
    public let appName: String
    public let title: String?
    public let bounds: HostRect
    public let layer: Int
    public let zIndex: Int
    public let displayId: String?
}

public struct HostSnapshotTruncation: Codable, Equatable, Sendable {
    public let elements: Bool
    public let depth: Bool
}

public struct HostSnapshotPayload: Codable, Equatable, Sendable {
    public let snapshotId: String
    public let capturedAt: Int64
    public let target: HostWindowTarget
    public let windowDigest: String
    public let focusedElementToken: String?
    public let selectedText: HostSelectedText?
    public let image: HostImageReference?
    public let displays: [HostDisplayInfo]
    public let obscuringRects: [HostRect]
    public let elements: [HostObservedElement]
    public let truncated: HostSnapshotTruncation
}

// MARK: - Tree source

/// The tree walk is written against this protocol rather than `AXUIElement`
/// directly so the bounds, truncation flags and digest inputs can be tested
/// without a live desktop. The Accessibility adapter lives in `HostAXNode`.
public protocol HostAccessibilityNode: AnyObject {
    var axElement: AXUIElement? { get }
    var role: String { get }
    var subrole: String? { get }
    var axIdentifier: String? { get }
    var title: String? { get }
    var label: String? { get }
    /// Untruncated. Truncation for the wire happens in the walker, and the
    /// digest is taken over this value — see §4.3.
    var value: String? { get }
    var placeholder: String? { get }
    var enabled: Bool { get }
    var focused: Bool { get }
    var selected: Bool? { get }
    /// Window-local logical points.
    var frameInWindow: CGRect? { get }
    var rawActionNames: [String] { get }
    var children: [HostAccessibilityNode] { get }
}

public struct HostTreeWalkBounds: Equatable, Sendable {
    public let maxElements: Int
    public let maxDepth: Int
    public let maxTextChars: Int

    public init(maxElements: Int, maxDepth: Int, maxTextChars: Int) {
        self.maxElements = maxElements
        self.maxDepth = maxDepth
        self.maxTextChars = maxTextChars
    }
}

public struct HostTreeWalkResult {
    public let elements: [HostObservedElement]
    public let bindings: [HostElementBinding]
    public let truncated: HostSnapshotTruncation
    public let focusedToken: String?
}

/// Breadth-agnostic depth-first walk. Nodes are numbered in traversal order, and
/// the token embeds the snapshot nonce so it can only ever be looked up in the
/// dictionary it came from — §4.2 forbids parsing an index back out of a token
/// and re-walking the tree, which is exactly the upstream defect being removed.
public func hostWalkTree(
    root: HostAccessibilityNode,
    pid: pid_t,
    processStartTime: UInt64,
    tokenPrefix: String,
    bounds: HostTreeWalkBounds
) -> HostTreeWalkResult {
    var elements: [HostObservedElement] = []
    var bindings: [HostElementBinding] = []
    var focusedToken: String?
    var hitElementBound = false
    var hitDepthBound = false
    var nextIndex = 0

    func token(for index: Int) -> String {
        "el_\(tokenPrefix)_\(index)"
    }

    func visit(
        _ node: HostAccessibilityNode,
        parentToken: String?,
        depth: Int,
        ancestorRoles: [String],
        siblingIndex: Int
    ) {
        guard elements.count < bounds.maxElements else {
            hitElementBound = true
            return
        }

        let selfToken = token(for: nextIndex)
        nextIndex += 1

        let label = hostTruncate(node.label, limit: bounds.maxTextChars)
        let value = hostTruncate(node.value, limit: bounds.maxTextChars)
        let placeholder = hostTruncate(node.placeholder, limit: bounds.maxTextChars)

        var truncatedFields: [HostElementTextField] = []
        if label.wasTruncated {
            truncatedFields.append(.label)
        }
        if value.wasTruncated {
            truncatedFields.append(.value)
        }
        if placeholder.wasTruncated {
            truncatedFields.append(.placeholder)
        }

        let actions = node.rawActionNames
            .compactMap(HostElementActionName.normalized(rawAXAction:))
            .reduce(into: [HostElementActionName]()) { unique, action in
                if !unique.contains(action) {
                    unique.append(action)
                }
            }

        let digestInput = HostElementDigestInput(
            role: node.role,
            subrole: node.subrole,
            axIdentifier: node.axIdentifier,
            title: node.title,
            label: node.label,
            untruncatedValue: node.value,
            frameInWindow: node.frameInWindow,
            actionNames: actions.map(\.rawValue),
            ancestorRoles: ancestorRoles,
            siblingIndex: siblingIndex
        )

        let observed = HostObservedElement(
            token: selfToken,
            parentToken: parentToken,
            depth: depth,
            role: node.role,
            subrole: node.subrole,
            axIdentifier: node.axIdentifier,
            label: label.text,
            value: value.text,
            placeholder: placeholder.text,
            enabled: node.enabled,
            focused: node.focused,
            selected: node.selected,
            frame: node.frameInWindow.map(HostRect.init),
            actions: actions,
            digest: hostElementDigest(digestInput),
            truncated: truncatedFields
        )

        elements.append(observed)
        bindings.append(
            HostElementBinding(
                token: selfToken,
                parentToken: parentToken,
                depth: depth,
                pid: pid,
                processStartTime: processStartTime,
                digestInput: digestInput,
                element: node.axElement,
                observed: observed
            )
        )

        if node.focused, focusedToken == nil {
            focusedToken = selfToken
        }

        let children = node.children
        if !children.isEmpty, depth == bounds.maxDepth {
            hitDepthBound = true
            return
        }

        // Ancestor roles are capped at 8 levels root-ward (§4.3). Keeping the
        // *nearest* eight is what makes the cap useful: a deep Electron tree
        // changes at the root far more often than next to the element.
        let childAncestors = Array(([node.role] + ancestorRoles).prefix(8))
        for (offset, child) in children.enumerated() {
            visit(
                child,
                parentToken: selfToken,
                depth: depth + 1,
                ancestorRoles: childAncestors,
                siblingIndex: offset
            )
        }
    }

    visit(root, parentToken: nil, depth: 0, ancestorRoles: [], siblingIndex: 0)

    return HostTreeWalkResult(
        elements: elements,
        bindings: bindings,
        truncated: HostSnapshotTruncation(elements: hitElementBound, depth: hitDepthBound),
        focusedToken: focusedToken
    )
}

public struct HostTruncatedText: Equatable, Sendable {
    public let text: String?
    public let wasTruncated: Bool
}

public func hostTruncate(_ value: String?, limit: Int) -> HostTruncatedText {
    guard let value else {
        return HostTruncatedText(text: nil, wasTruncated: false)
    }

    guard value.count > limit else {
        return HostTruncatedText(text: value, wasTruncated: false)
    }

    return HostTruncatedText(text: String(value.prefix(limit)), wasTruncated: true)
}
