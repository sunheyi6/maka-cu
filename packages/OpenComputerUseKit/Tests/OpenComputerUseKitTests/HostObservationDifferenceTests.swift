import XCTest
@testable import OpenComputerUseKit

final class HostObservationDifferenceTests: XCTestCase {
    func testRootAndAppendRevisionsPreserveStableIds() {
        let root = hostAssignRootStableIds(
            revision(
                node("R", children: [
                    node("A"),
                    node("B", children: [node("C")]),
                ])
            )
        )
        XCTAssertEqual(flatten(root).map(\.stableId), [0, 1, 2, 3])

        let previous = hostAssignRootStableIds(
            revision(node("R", children: [node("A"), node("B")]))
        )
        let appended = hostAppendObservationRevision(
            previous: previous,
            current: revision(node("R", children: [node("X"), node("A"), node("B")]))
        )
        XCTAssertEqual(
            appended.revision.roots[0].children.map {
                "\($0.identity):\($0.stableId ?? -1)"
            },
            ["X:3", "A:1", "B:2"]
        )
    }

    func testDiffMatchesSiblingIdentityAndOnlyPrimaryTextUpdates() {
        let previous = hostAssignRootStableIds(
            revision(
                node("R", text: "root", children: [
                    node("A", text: "same"),
                    node("B", text: "before"),
                ])
            )
        )
        let appended = hostAppendObservationRevision(
            previous: previous,
            current: revision(
                node("R", text: "root", children: [
                    node("B", text: "after"),
                    node("A", text: "same"),
                ])
            )
        )

        XCTAssertFalse(appended.changes.contains { $0.kind == .insert })
        XCTAssertFalse(appended.changes.contains { $0.kind == .remove })
        XCTAssertEqual(
            appended.changes.first { $0.node.identity == "A" }?.kind,
            HostObservationChangeKind.none
        )
        XCTAssertEqual(
            appended.changes.first { $0.node.identity == "B" }?.kind,
            .update
        )
        XCTAssertEqual(
            appended.revision.roots[0].children.map(\.stableId),
            [2, 1]
        )
    }

    func testChangeOrderingAndRemovedRangesMatchRecoveredContract() {
        let sample = node("N")
        let sorted = hostSortObservationChanges([
            change(.update, [0], sample),
            change(.insert, [0], sample),
            change(.none, [0], sample),
            change(.remove, [0], sample),
            change(.insert, [1], sample),
            change(.insert, [0, 2], sample),
            change(.insert, [0, 1], sample),
        ])
        XCTAssertEqual(
            sorted.map { "\($0.path.map(String.init).joined(separator: ".")):\($0.kind.rawValue)" },
            [
                "0:none",
                "0:remove",
                "0:insert",
                "0:update",
                "0.1:insert",
                "0.2:insert",
                "1:insert",
            ]
        )
        XCTAssertEqual(
            hostCompressRemovedStableIds([9, 7, 8, 14, 12, 13]),
            [
                HostObservationRemovedRange(start: 7, end: 9),
                HostObservationRemovedRange(start: 12, end: 14),
            ]
        )
    }

    func testRemovedNodeIncludesEveryStableIdInItsSubtree() {
        let previous = hostAssignRootStableIds(
            revision(node("R", children: [node("A", children: [node("B")])]))
        )
        let appended = hostAppendObservationRevision(
            previous: previous,
            current: revision(node("R"))
        )
        XCTAssertEqual(appended.removedStableIds, [1, 2])
    }

    func testDifferenceBudgetAndNoChangePresentation() {
        XCTAssertEqual(
            hostChooseDifferencePresentation(
                differenceLineCount: 6,
                effectiveChangeCount: 1,
                fullLineCount: 5,
                removedSummaryLineCount: 2
            ),
            .full
        )
        XCTAssertEqual(
            hostChooseDifferencePresentation(
                differenceLineCount: 0,
                effectiveChangeCount: 0,
                fullLineCount: 5
            ),
            .noChange
        )
        XCTAssertEqual(
            hostChooseDifferencePresentation(
                differenceLineCount: 9,
                effectiveChangeCount: 1,
                fullLineCount: 1,
                removedSummaryLineCount: 9,
                ignoreDifferenceLineBudget: true
            ),
            .difference
        )
    }

    func testFlatObservedTreesPreserveIdsAcrossNewSnapshotTokens() {
        let previousWalk = hostWalkTree(
            root: FakeNode(
                role: "AXWindow",
                axIdentifier: "root",
                children: [
                    FakeNode(role: "AXButton", axIdentifier: "a", title: "A"),
                    FakeNode(role: "AXButton", axIdentifier: "b", title: "B"),
                ]
            ),
            pid: hostTestPid,
            processStartTime: hostTestProcessStartTime,
            tokenPrefix: "old",
            bounds: HostTreeWalkBounds(maxElements: 20, maxDepth: 10, maxTextChars: 100)
        )
        let previous = hostAssignRootStableIds(
            hostObservationRevision(from: previousWalk.elements)
        )

        let currentWalk = hostWalkTree(
            root: FakeNode(
                role: "AXWindow",
                axIdentifier: "root",
                children: [
                    FakeNode(role: "AXButton", axIdentifier: "x", title: "X"),
                    FakeNode(role: "AXButton", axIdentifier: "a", title: "A"),
                    FakeNode(role: "AXButton", axIdentifier: "b", title: "B"),
                ]
            ),
            pid: hostTestPid,
            processStartTime: hostTestProcessStartTime,
            tokenPrefix: "new",
            bounds: HostTreeWalkBounds(maxElements: 20, maxDepth: 10, maxTextChars: 100)
        )
        let appended = hostAppendObservationRevision(
            previous: previous,
            current: hostObservationRevision(from: currentWalk.elements)
        )

        XCTAssertEqual(
            appended.revision.roots[0].children.map {
                "\($0.identity):\($0.stableId ?? -1)"
            },
            [
                "AXButton\u{1e}\u{1e}id:x:3",
                "AXButton\u{1e}\u{1e}id:a:1",
                "AXButton\u{1e}\u{1e}id:b:2",
            ]
        )
    }

    func testSpentSnapshotRemainsTheLatestDifferenceBaseline() throws {
        let registry = HostSnapshotRegistry(limits: HostLimits())
        try registry.beginSession("s1", captureScope: .window)
        let snapshot = hostTestSnapshot(registry: registry, session: "s1")
        registry.register(snapshot)
        registry.spend(snapshot)

        XCTAssertTrue(
            registry.latestDifferenceBaseline(
                session: "s1",
                pid: snapshot.pid,
                windowId: snapshot.windowId
            ) === snapshot
        )
    }

    func testDifferencePayloadCarriesStableIdsTokensAndRemovedRanges() {
        let previous = hostAssignRootStableIds(
            revision(node("R", children: [node("A"), node("B")]))
        )
        let appended = hostAppendObservationRevision(
            previous: previous,
            current: revision(node("R", children: [node("A"), node("X")]))
        )
        let payload = hostObservationDifferencePayload(
            baseSnapshotId: "snap-old",
            appendResult: appended,
            fullLineCount: 3
        )

        XCTAssertEqual(payload.baseSnapshotId, "snap-old")
        XCTAssertEqual(payload.presentation, .difference)
        XCTAssertEqual(
            payload.changes.map {
                "\($0.kind.rawValue):\($0.stableId):\($0.token ?? "nil")"
            },
            ["remove:2:nil", "insert:3:X"]
        )
        XCTAssertEqual(
            payload.removedStableIdRanges,
            [HostObservationRemovedRange(start: 2, end: 2)]
        )
    }

    func testRemovedOnlyDifferenceCountsTheCompressedSummaryOnce() {
        let previous = hostAssignRootStableIds(
            revision(
                node("R", children: [
                    node("A"),
                    node("B"),
                    node("C"),
                    node("D"),
                ])
            )
        )
        let appended = hostAppendObservationRevision(
            previous: previous,
            current: revision(node("R"))
        )
        let payload = hostObservationDifferencePayload(
            baseSnapshotId: "snap-old",
            appendResult: appended,
            fullLineCount: 1
        )

        XCTAssertEqual(payload.presentation, .difference)
        XCTAssertEqual(
            payload.removedStableIdRanges,
            [HostObservationRemovedRange(start: 1, end: 4)]
        )
    }

    private func revision(_ roots: HostObservationRevisionNode...) -> HostObservationRevision {
        HostObservationRevision(roots: roots)
    }

    private func node(
        _ identity: String,
        text: String? = nil,
        children: [HostObservationRevisionNode] = []
    ) -> HostObservationRevisionNode {
        HostObservationRevisionNode(
            identity: identity,
            primaryText: text,
            children: children
        )
    }

    private func change(
        _ kind: HostObservationChangeKind,
        _ path: [Int],
        _ node: HostObservationRevisionNode
    ) -> HostObservationChange {
        HostObservationChange(kind: kind, path: path, node: node)
    }

    private func flatten(
        _ revision: HostObservationRevision
    ) -> [HostObservationRevisionNode] {
        var result: [HostObservationRevisionNode] = []
        func visit(_ nodes: [HostObservationRevisionNode]) {
            for node in nodes {
                result.append(node)
                visit(node.children)
            }
        }
        visit(revision.roots)
        return result
    }
}
