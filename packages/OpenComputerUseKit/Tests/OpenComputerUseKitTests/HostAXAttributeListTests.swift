import ApplicationServices
import Foundation
import XCTest
@testable import OpenComputerUseKit

/// The guard for the defect that batching introduced and a live differential
/// caught: `HostAXNode` asked for three of the four attributes
/// `childTraversalAttributes` can name, then served `AXContents` out of the slot
/// holding `AXChildren`. Finder's outline came back with its columns instead of
/// its rows, 156 elements became 240, and nothing errored.
///
/// These run without a desktop, because the shape of the mistake is a list that
/// grew on one side and not the other, and that is checkable from the lists.
final class HostAXAttributeListTests: XCTestCase {
    func testEveryTraversalAttributeIsInTheDeclaredSet() {
        let declared = Set(hostChildTraversalAttributeNames)
        let roles: [String?] = [
            nil, "AXWindow", "AXGroup",
            kAXOutlineRole as String, kAXListRole as String, kAXTableRole as String, "AXBrowser",
        ]

        for role in roles {
            for hasRows in [false, true] {
                for hasVisible in [false, true] {
                    let produced = childTraversalAttributes(
                        role: role,
                        hasRows: hasRows,
                        hasVisibleChildren: hasVisible
                    )
                    XCTAssertTrue(
                        Set(produced).isSubset(of: declared),
                        "role \(role ?? "nil") names \(Set(produced).subtracting(declared)), which no batched reader asks for"
                    )
                }
            }
        }
    }

    func testTheBatchedReadCoversEveryTraversalAttribute() {
        let batched = Set(HostAXNode.batchedAttributeNames)
        for name in hostChildTraversalAttributeNames {
            XCTAssertTrue(batched.contains(name), "\(name) is traversed but never batched")
        }
    }

    /// Positional decoding: a duplicate name would make two fields share a slot,
    /// and the reply is read by index.
    func testBatchedAttributeNamesAreUnique() {
        XCTAssertEqual(
            HostAXNode.batchedAttributeNames.count,
            Set(HostAXNode.batchedAttributeNames).count,
            "a repeated attribute name makes the positional reply ambiguous"
        )
    }

    /// The child arrays are decoded from the tail of the request, so they have to
    /// be the tail of it.
    func testTraversalAttributesAreTheTailOfTheBatch() {
        XCTAssertEqual(
            Array(HostAXNode.batchedAttributeNames.suffix(hostChildTraversalAttributeNames.count)),
            hostChildTraversalAttributeNames
        )
    }
}
