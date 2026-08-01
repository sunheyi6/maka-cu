import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
@testable import OpenComputerUseKit

/// The node `HostAXNode` used to be: one `AXUIElementCopyAttributeValue` per
/// attribute per read, no memory between reads, and an ancestor chain climbed
/// from scratch for every element.
///
/// It is kept here rather than deleted because the batched replacement is only
/// worth having if it answers identically, and "identically" has to be checked
/// against something. `HostObserveBatchedReadLiveTests` walks a live window with
/// both and compares every emitted field, including the §4.3 digest — which is
/// the assertion that matters, because a digest that moved would refuse every
/// dispatch against the element it described.
///
/// It is also the baseline column in the benchmark. A before/after taken from
/// two git revisions is two machine states; taken from two nodes in one process,
/// interleaved, it is one.
final class LegacyHostAXNode: HostAccessibilityNode {
    let element: AXUIElement
    private let windowBounds: CGRect?
    private let focusedElement: AXUIElement?
    private let dropsAppleMenu: Bool

    init(
        element: AXUIElement,
        windowBounds: CGRect?,
        focusedElement: AXUIElement?,
        dropsAppleMenu: Bool = false
    ) {
        self.element = element
        self.windowBounds = windowBounds
        self.focusedElement = focusedElement
        self.dropsAppleMenu = dropsAppleMenu
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
        guard let windowBounds, let frame = HostAX.frame(element) else {
            return nil
        }

        return windowRelativeFrame(elementFrame: frame, windowBounds: windowBounds)
    }

    var rawActionNames: [String] {
        HostAX.actionNames(element)
    }

    var liveAncestorRoles: [String]? {
        HostAX.ancestorRoles(of: element)
    }

    var children: [HostAccessibilityNode] {
        HostAX.traversedChildren(of: element, dropsAppleMenu: dropsAppleMenu)
            .map {
                LegacyHostAXNode(element: $0, windowBounds: windowBounds, focusedElement: focusedElement)
            }
    }
}
