import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import XCTest
@testable import OpenComputerUseKit

/// The one assertion that makes the batched read safe to ship: against real
/// windows, a walk that reads every attribute in one call emits byte-identical
/// elements to a walk that reads them one at a time.
///
///     OPEN_COMPUTER_USE_RUN_OBSERVE_BENCHMARK=1 \
///         swift test --filter HostObserveBatchedReadLiveTests
///
/// It compares the §4.3 digest as well as the fields, because the digest is what
/// `dispatch.element` echoes back: a batched read that produced a different
/// digest for the same element would refuse every dispatch with
/// `element_digest_mismatch` and look like a stale frame rather than like this.
///
/// Live only. `AXUIElementCopyMultipleAttributeValues` has no fixture — the
/// behaviour under test is what real applications return for attributes they do
/// not implement, and a fake would be a fake of the answer being checked.
final class HostObserveBatchedReadLiveTests: XCTestCase {
    func testBatchedAndSingleAttributeWalksEmitTheSameElements() throws {
        guard ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_RUN_OBSERVE_BENCHMARK"] == "1" else {
            throw XCTSkip("Set OPEN_COMPUTER_USE_RUN_OBSERVE_BENCHMARK=1 to run the batched-read differential")
        }
        guard AXIsProcessTrusted() else {
            throw XCTSkip("Accessibility permission is required")
        }
        guard !hostScreenIsLocked() else {
            throw XCTSkip("A locked screen reports a menu bar and nothing else")
        }

        let windows = HostWindowInventory.onScreenWindows().filter { $0.layer == 0 }
        var compared = 0
        var unstable: [String] = []

        for window in windows.prefix(12) {
            guard
                let startTime = hostProcessStartTime(pid: window.pid),
                let element = HostAX.window(pid: window.pid, windowId: window.windowId, bounds: window.bounds)
            else {
                continue
            }

            let focused = HostAX.focusedElement(pid: window.pid)
            let bounds = HostTreeWalkBounds(maxElements: 400, maxDepth: 64, maxTextChars: 400)

            let legacy = hostWalkTree(
                root: LegacyHostAXNode(element: element, windowBounds: window.bounds, focusedElement: focused),
                pid: window.pid,
                processStartTime: startTime,
                tokenPrefix: "diff",
                bounds: bounds
            )
            let batched = hostWalkTree(
                root: HostAXNode(element: element, windowBounds: window.bounds, focusedElement: focused),
                pid: window.pid,
                processStartTime: startTime,
                tokenPrefix: "diff",
                bounds: bounds
            )
            // The control, taken on both sides. A window that does not answer
            // two identical walks the same way cannot say anything about a
            // third, and several do not: Finder's outline materialises rows as
            // it is read, one of its filename labels alternates between 51 and
            // 69 points wide, and a System Settings cell reports height 0 until
            // it has laid out.
            //
            // One-sided was not enough. Checking only the legacy pair let a
            // value that toggles pass the control whenever the two legacy walks
            // happened to catch the same phase, and the batched walk between
            // them caught the other — which failed one run in three and blamed
            // the read strategy for a label resizing.
            let legacyAgain = hostWalkTree(
                root: LegacyHostAXNode(element: element, windowBounds: window.bounds, focusedElement: focused),
                pid: window.pid,
                processStartTime: startTime,
                tokenPrefix: "diff",
                bounds: bounds
            )
            let batchedAgain = hostWalkTree(
                root: HostAXNode(element: element, windowBounds: window.bounds, focusedElement: focused),
                pid: window.pid,
                processStartTime: startTime,
                tokenPrefix: "diff",
                bounds: bounds
            )

            guard legacy.elements == legacyAgain.elements, batched.elements == batchedAgain.elements else {
                unstable.append(window.appName)
                continue
            }

            compared += 1
            assertSameElements(legacy.elements, batched.elements, context: window.appName)
            XCTAssertEqual(legacy.focusedToken, batched.focusedToken, "focused element moved in \(window.appName)")
            XCTAssertEqual(legacy.truncated, batched.truncated, "truncation flags moved in \(window.appName)")
        }

        print("batched-read differential: compared \(compared) windows, skipped \(unstable) as not stable across two identical walks")

        // Without this the suite passes on a machine with nothing on screen,
        // which is the shape every live test in this repository has been bitten
        // by at least once.
        XCTAssertGreaterThan(compared, 2, "not enough stable windows on screen to compare")
    }

    /// The menu bar reaches the same code by a different door: `dropsAppleMenu`
    /// is set on the root and the nodes carry no window to be relative to, so a
    /// frame that the batched read newly returns would show up here and nowhere
    /// else.
    func testBatchedAndSingleAttributeMenuWalksEmitTheSameElements() throws {
        guard ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_RUN_OBSERVE_BENCHMARK"] == "1" else {
            throw XCTSkip("Set OPEN_COMPUTER_USE_RUN_OBSERVE_BENCHMARK=1 to run the batched-read differential")
        }
        guard AXIsProcessTrusted() else {
            throw XCTSkip("Accessibility permission is required")
        }

        let windows = HostWindowInventory.onScreenWindows().filter { $0.layer == 0 }
        var compared = 0

        for window in windows.prefix(12) {
            guard
                let startTime = hostProcessStartTime(pid: window.pid),
                let menuBar = HostAX.menuBar(pid: window.pid)
            else {
                continue
            }

            let bounds = HostTreeWalkBounds(maxElements: 400, maxDepth: 64, maxTextChars: 400)
            let legacy = hostWalkTree(
                root: LegacyHostAXNode(
                    element: menuBar,
                    windowBounds: nil,
                    focusedElement: nil,
                    dropsAppleMenu: true
                ),
                pid: window.pid,
                processStartTime: startTime,
                tokenPrefix: "diffmenu",
                bounds: bounds,
                isMenu: true
            )
            let batched = hostWalkTree(
                root: HostAXNode(
                    element: menuBar,
                    windowBounds: nil,
                    focusedElement: nil,
                    dropsAppleMenu: true
                ),
                pid: window.pid,
                processStartTime: startTime,
                tokenPrefix: "diffmenu",
                bounds: bounds,
                isMenu: true
            )

            let legacyAgain = hostWalkTree(
                root: LegacyHostAXNode(
                    element: menuBar,
                    windowBounds: nil,
                    focusedElement: nil,
                    dropsAppleMenu: true
                ),
                pid: window.pid,
                processStartTime: startTime,
                tokenPrefix: "diffmenu",
                bounds: bounds,
                isMenu: true
            )

            guard legacy.elements == legacyAgain.elements, legacy.elements.count > 1 else {
                continue
            }

            compared += 1
            assertSameElements(legacy.elements, batched.elements, context: "\(window.appName) menu bar")
        }

        XCTAssertGreaterThan(compared, 1, "not enough menu bars on screen to compare")
    }

    /// The shareable-content cache, checked the only way that matters: an image
    /// taken through a cached `SCShareableContent` has to be the same image.
    ///
    /// Dimensions rather than pixels. The failure the cache could cause is a
    /// buffer sized from a stale `contentRect` — a window that resized while the
    /// content sat in the cache — and that shows up as a different width and
    /// height, and as a `scale` computed against them. Pixel equality would fail
    /// on a blinking caret and prove nothing about staleness.
    func testCachedShareableContentCapturesTheSameImage() throws {
        guard ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_RUN_OBSERVE_BENCHMARK"] == "1" else {
            throw XCTSkip("Set OPEN_COMPUTER_USE_RUN_OBSERVE_BENCHMARK=1 to run the capture cache differential")
        }
        guard !hostScreenIsLocked() else {
            throw XCTSkip("A locked screen captures nothing")
        }

        var compared = 0
        for window in HostWindowInventory.onScreenWindows().filter({ $0.layer == 0 }).prefix(10) {
            HostShareableContentCache.invalidate()
            guard case .success(let fresh) = HostCapture.captureWindow(windowId: window.windowId, scope: .window) else {
                continue
            }
            guard case .success(let cached) = HostCapture.captureWindow(windowId: window.windowId, scope: .window) else {
                continue
            }

            compared += 1
            XCTAssertEqual(fresh.width, cached.width, "\(window.appName) width moved with the content cache")
            XCTAssertEqual(fresh.height, cached.height, "\(window.appName) height moved with the content cache")
        }

        XCTAssertGreaterThan(compared, 2, "not enough capturable windows on screen")
    }

    /// A window that moves between the fetch and the capture must not be served
    /// from the cache. Rather than move a real window, this asks the validator
    /// directly what it does with content it has and a window the window server
    /// no longer lists — which is the same branch a moved window takes.
    func testCacheIsNotUsedForAWindowTheWindowServerDoesNotConfirm() throws {
        guard ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_RUN_OBSERVE_BENCHMARK"] == "1" else {
            throw XCTSkip("Set OPEN_COMPUTER_USE_RUN_OBSERVE_BENCHMARK=1 to run the capture cache differential")
        }

        HostShareableContentCache.invalidate()
        // A window id no process owns. The validator cannot confirm it, so the
        // capture has to fail rather than be answered out of the cache.
        let result = HostCapture.captureWindow(windowId: CGWindowID(UInt32.max - 1), scope: .window)
        guard case .failure(let error) = result else {
            return XCTFail("a window id nobody owns cannot produce an image")
        }
        XCTAssertEqual(error.code, .captureFailed)
    }

    /// Field by field, and it reports the field. `XCTAssertEqual` on two arrays
    /// of 400 elements prints both arrays, which is 380 KB of console for a one
    /// character difference and is why the first run of this told nobody
    /// anything.
    private func assertSameElements(
        _ legacy: [HostObservedElement],
        _ batched: [HostObservedElement],
        context: String
    ) {
        for (index, pair) in zip(legacy, batched).enumerated() {
            let (a, b) = pair
            var differences: [String] = []
            func check<T: Equatable>(_ name: String, _ lhs: T, _ rhs: T) {
                if lhs != rhs {
                    differences.append("\(name): 1by1=\(lhs) batch=\(rhs)")
                }
            }

            check("role", a.role, b.role)
            check("subrole", a.subrole, b.subrole)
            check("axIdentifier", a.axIdentifier, b.axIdentifier)
            check("title", a.title, b.title)
            check("label", a.label, b.label)
            check("value", a.value, b.value)
            check("placeholder", a.placeholder, b.placeholder)
            check("enabled", a.enabled, b.enabled)
            check("focused", a.focused, b.focused)
            check("selected", a.selected, b.selected)
            check("frame", a.frame, b.frame)
            check("actions", a.actions, b.actions)
            check("depth", a.depth, b.depth)
            check("parentToken", a.parentToken, b.parentToken)
            check("truncated", a.truncated, b.truncated)
            check("digest", a.digest, b.digest)

            guard !differences.isEmpty else {
                continue
            }

            XCTFail(
                "\(context) element \(index) (\(a.role) \(a.title ?? a.label ?? "-")) differs: "
                    + differences.joined(separator: "; ")
            )
            return
        }
    }
}
