import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import XCTest
@testable import OpenComputerUseKit

/// Diagnostic: for every element of every on-screen window, ask each attribute
/// twice — once alone, once inside the batch — and report where the two answers
/// disagree. It is here because a differential failure on the whole tree names
/// the symptom (a tree of a different shape) and not the attribute.
final class HostAXBatchedAttributeDiagnosticTests: XCTestCase {
    func testEveryBatchedAttributeAnswersLikeItsOwnRead() throws {
        guard ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_RUN_OBSERVE_BENCHMARK"] == "1" else {
            throw XCTSkip("Set OPEN_COMPUTER_USE_RUN_OBSERVE_BENCHMARK=1 to run the batched-read diagnostic")
        }
        guard AXIsProcessTrusted() else {
            throw XCTSkip("Accessibility permission is required")
        }

        let names = HostAXNode.batchedAttributeNames
        var disagreements: [String: Int] = [:]
        var samples: [String: String] = [:]
        var visited = 0

        for window in HostWindowInventory.onScreenWindows().filter({ $0.layer == 0 }).prefix(12) {
            guard let root = HostAX.window(pid: window.pid, windowId: window.windowId, bounds: window.bounds) else {
                continue
            }

            var queue = [root]
            var seen = 0
            while let element = queue.popLast(), seen < 300 {
                seen += 1
                visited += 1

                let batched = HostAX.attributes(element, names)
                for (index, name) in names.enumerated() {
                    let single = HostAX.attribute(element, name)
                    let batchedValue = batched?[index] ?? nil
                    let a = describe(single)
                    let b = describe(batchedValue)
                    guard a != b else {
                        continue
                    }
                    disagreements[name, default: 0] += 1
                    if samples[name] == nil {
                        samples[name] = "\(window.appName) \(HostAX.string(element, kAXRoleAttribute) ?? "?"): alone=\(a) batched=\(b)"
                    }
                }

                queue.append(contentsOf: HostAX.children(of: element))
            }
        }

        print("")
        print("=== batched vs single attribute reads over \(visited) elements ===")
        for name in names {
            let count = disagreements[name] ?? 0
            print("\(name): \(count)\(count > 0 ? "  e.g. " + (samples[name] ?? "") : "")")
        }

        XCTAssertGreaterThan(visited, 100, "not enough of the desktop was read to conclude anything")

        // Not zero, and the reason is not slack. Two reads of a live desktop are
        // two instants: measured over 24 256 comparisons, four disagreed and all
        // four were values that were changing — a scrolled list re-using a cell's
        // label, a cell reporting height 0 until it had laid out. A threshold of
        // zero here would fail on the desktop moving rather than on the read.
        let total = disagreements.values.reduce(0, +)
        let comparisons = visited * names.count
        XCTAssertLessThan(
            Double(total) / Double(comparisons),
            0.005,
            "the batched read is answering differently from a single read: \(disagreements)"
        )
    }

    /// Order sensitivity. If a tree answers differently depending on which walk
    /// ran first, the difference is the desktop and not the read.
    func testWalkOrderDoesNotDecideTheTree() throws {
        guard ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_RUN_OBSERVE_BENCHMARK"] == "1" else {
            throw XCTSkip("Set OPEN_COMPUTER_USE_RUN_OBSERVE_BENCHMARK=1")
        }
        guard AXIsProcessTrusted() else {
            throw XCTSkip("Accessibility permission is required")
        }

        for window in HostWindowInventory.onScreenWindows().filter({ $0.layer == 0 }).prefix(12) {
            guard
                let startTime = hostProcessStartTime(pid: window.pid),
                let element = HostAX.window(pid: window.pid, windowId: window.windowId, bounds: window.bounds)
            else {
                continue
            }

            let bounds = HostTreeWalkBounds(maxElements: 1500, maxDepth: 64, maxTextChars: 400)
            func legacyWalk() -> [HostObservedElement] {
                hostWalkTree(
                    root: LegacyHostAXNode(element: element, windowBounds: window.bounds, focusedElement: nil),
                    pid: window.pid, processStartTime: startTime, tokenPrefix: "o", bounds: bounds
                ).elements
            }
            func batchedWalk() -> [HostObservedElement] {
                hostWalkTree(
                    root: HostAXNode(element: element, windowBounds: window.bounds, focusedElement: nil),
                    pid: window.pid, processStartTime: startTime, tokenPrefix: "o", bounds: bounds
                ).elements
            }

            var counts: [String] = []
            var legacyCounts: [Int] = []
            var batchedCounts: [Int] = []
            for _ in 0..<3 {
                let legacy = legacyWalk().count
                let batched = batchedWalk().count
                legacyCounts.append(legacy)
                batchedCounts.append(batched)
                counts.append("L\(legacy)")
                counts.append("B\(batched)")
            }
            print("order probe \(window.appName): \(counts.joined(separator: " "))")

            // Element counts, not contents. A tree of a different *size* is the
            // signature of a traversal that took different edges — which is what
            // filing `AXContents` under `AXChildren` did to Finder, 156 elements
            // against 240 — and unlike a field value it does not move because a
            // label was being laid out.
            guard Set(legacyCounts).count == 1, Set(batchedCounts).count == 1 else {
                continue
            }
            XCTAssertEqual(
                legacyCounts[0],
                batchedCounts[0],
                "\(window.appName) is traversed differently depending on how its attributes are read"
            )
        }
    }

    /// What the old per-element traffic was made of. The ancestor climb is
    /// measured on its own because it was the largest single piece and the one
    /// nobody would guess: it reads no attribute the wire carries.
    func testWhereTheOldRoundTripsWent() throws {
        guard ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_RUN_OBSERVE_BENCHMARK"] == "1" else {
            throw XCTSkip("Set OPEN_COMPUTER_USE_RUN_OBSERVE_BENCHMARK=1")
        }
        guard AXIsProcessTrusted() else {
            throw XCTSkip("Accessibility permission is required")
        }

        print("")
        print("=== per element, the old walk's round trips by cause ===")

        for window in HostWindowInventory.onScreenWindows().filter({ $0.layer == 0 }).prefix(12) {
            guard
                let startTime = hostProcessStartTime(pid: window.pid),
                let root = HostAX.window(pid: window.pid, windowId: window.windowId, bounds: window.bounds)
            else {
                continue
            }

            HostAXTelemetry.reset()
            let walk = hostWalkTree(
                root: LegacyHostAXNode(element: root, windowBounds: window.bounds, focusedElement: nil),
                pid: window.pid,
                processStartTime: startTime,
                tokenPrefix: "cause",
                bounds: HostTreeWalkBounds(maxElements: 400, maxDepth: 64, maxTextChars: 400)
            )
            let total = HostAXTelemetry.roundTrips
            let count = walk.elements.count
            guard count > 20 else {
                continue
            }

            var elements: [AXUIElement] = []
            var queue = [root]
            while let element = queue.popLast(), elements.count < count {
                elements.append(element)
                queue.append(contentsOf: HostAX.children(of: element))
            }

            HostAXTelemetry.reset()
            for element in elements {
                _ = HostAX.ancestorRoles(of: element)
            }
            let ancestors = HostAXTelemetry.roundTrips

            HostAXTelemetry.reset()
            for element in elements {
                _ = HostAX.children(of: element)
            }
            let children = HostAXTelemetry.roundTrips

            print(String(
                format: "%@: %.1f total, %.1f ancestor climb, %.1f child lists, %.1f field reads",
                window.appName,
                Double(total) / Double(count),
                Double(ancestors) / Double(elements.count),
                Double(children) / Double(elements.count),
                Double(total) / Double(count) - Double(ancestors) / Double(elements.count) - Double(children) / Double(elements.count)
            ))
        }
    }

    /// Does reading several elements at once beat reading them one after
    /// another? Accessibility round trips are a wait, not a computation, so
    /// concurrency would help if the answering side served them in parallel —
    /// and would not if it serialises on the observed application's main run
    /// loop, which is where an AppKit application answers Accessibility from.
    ///
    /// Measured rather than assumed, and left in as the record of the answer.
    func testConcurrentAttributeReadsAgainstSerialOnes() throws {
        guard ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_RUN_OBSERVE_BENCHMARK"] == "1" else {
            throw XCTSkip("Set OPEN_COMPUTER_USE_RUN_OBSERVE_BENCHMARK=1")
        }
        guard AXIsProcessTrusted() else {
            throw XCTSkip("Accessibility permission is required")
        }

        let names = HostAXNode.batchedAttributeNames
        print("")
        print("=== serial against concurrent attribute reads, median of 5, ms ===")

        for window in HostWindowInventory.onScreenWindows().filter({ $0.layer == 0 }).prefix(12) {
            guard let root = HostAX.window(pid: window.pid, windowId: window.windowId, bounds: window.bounds) else {
                continue
            }

            var elements: [AXUIElement] = []
            var queue = [root]
            while let element = queue.popLast(), elements.count < 400 {
                elements.append(element)
                queue.append(contentsOf: HostAX.children(of: element))
            }
            guard elements.count > 60 else {
                continue
            }

            let box = ElementBox(elements)
            var serial: [Double] = []
            var concurrent: [Double] = []
            for _ in 0..<5 {
                var start = DispatchTime.now().uptimeNanoseconds
                for element in elements {
                    _ = HostAX.attributes(element, names)
                }
                serial.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)

                start = DispatchTime.now().uptimeNanoseconds
                DispatchQueue.concurrentPerform(iterations: 8) { lane in
                    for index in stride(from: lane, to: box.elements.count, by: 8) {
                        _ = HostAX.attributes(box.elements[index], names)
                    }
                }
                concurrent.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }

            let s = serial.sorted()[serial.count / 2]
            let c = concurrent.sorted()[concurrent.count / 2]
            print(String(format: "%@ (%d elements): serial %.1f, 8 lanes %.1f, %.2fx", window.appName, elements.count, s, c, s / c))
        }
    }

    private final class ElementBox: @unchecked Sendable {
        let elements: [AXUIElement]
        init(_ elements: [AXUIElement]) {
            self.elements = elements
        }
    }

    private func describe(_ value: CFTypeRef?) -> String {
        guard let value else {
            return "nil"
        }
        if let text = value as? String {
            return "str(\(text.prefix(40)))"
        }
        if let number = value as? NSNumber {
            return "num(\(number))"
        }
        if let elements = value as? [AXUIElement] {
            return "elements(\(elements.count))"
        }
        if CFGetTypeID(value) == AXUIElementGetTypeID() {
            return "element"
        }
        if CFGetTypeID(value) == AXValueGetTypeID() {
            let axValue = value as! AXValue
            switch AXValueGetType(axValue) {
            case .cgPoint:
                var point = CGPoint.zero
                AXValueGetValue(axValue, .cgPoint, &point)
                return "point(\(point.x),\(point.y))"
            case .cgSize:
                var size = CGSize.zero
                AXValueGetValue(axValue, .cgSize, &size)
                return "size(\(size.width),\(size.height))"
            case .axError:
                return "nil"
            default:
                return "axvalue"
            }
        }
        return "other"
    }
}
