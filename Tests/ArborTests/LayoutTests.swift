import XCTest
@testable import Arbor

final class PaneWidthTests: XCTestCase {
    func testWidthsAlwaysFillTheSpaceExactly() {
        for available: CGFloat in [300, 520, 760, 1200] {
            for fractions: [CGFloat] in [[1, 1, 1], [3, 1, 1], [0.2, 2, 0.8]] {
                let widths = PanesView.widths(fractions, available: available, minimum: 240)
                XCTAssertEqual(widths.reduce(0, +), available, accuracy: 0.001, "never wider than the window: \(fractions) in \(available)")
            }
        }
    }

    func testNarrowSpaceSharesEquallyInsteadOfOverflowing() {
        // Three panes in 520pt can't each have 240pt: they get a third each rather than spilling over.
        let widths = PanesView.widths([3, 1, 1], available: 520, minimum: 240)
        for width in widths { XCTAssertEqual(width, 520 / 3, accuracy: 0.001) }
    }

    func testSmallPaneIsHeldAtTheMinimumWhileOthersShareTheRest() {
        let widths = PanesView.widths([4, 4, 0.5], available: 900, minimum: 240)
        XCTAssertEqual(widths[2], 240, accuracy: 0.001)
        XCTAssertEqual(widths[0], 330, accuracy: 0.001)
        XCTAssertEqual(widths[1], 330, accuracy: 0.001)
    }

    func testWideSpaceKeepsProportions() {
        let widths = PanesView.widths([2, 1], available: 900, minimum: 240)
        XCTAssertEqual(widths[0], 600, accuracy: 0.001)
        XCTAssertEqual(widths[1], 300, accuracy: 0.001)
    }
}

@MainActor
final class NewWindowLayoutTests: XCTestCase {
    private let last = WorkspaceSnapshot(
        panes: [PaneSnapshot(tabs: [TabSnapshot(path: "/tmp")], activeTab: 0)], paneCount: 3, activePane: 2,
        showInspector: true, tint: "coral", showSidebar: false, paneFractions: [2, 1, 1])

    func testReopeningWithNoWindowRestoresTheLastOneWhole() {
        let snapshot = WorkspaceRegistry.snapshotForNewWindow(last: last, focused: nil, paneSetting: 0)
        XCTAssertEqual(snapshot, last)
    }

    func testFixedPaneSettingOverridesTheCount() {
        let snapshot = WorkspaceRegistry.snapshotForNewWindow(last: last, focused: nil, paneSetting: 1)
        XCTAssertEqual(snapshot?.paneCount, 1)
        XCTAssertEqual(snapshot?.activePane, 0, "the active pane stays within the visible ones")
        XCTAssertEqual(snapshot?.panes, last.panes, "tabs still come back")

        let fresh = WorkspaceRegistry.snapshotForNewWindow(last: nil, focused: nil, paneSetting: 3)
        XCTAssertEqual(fresh?.paneCount, 3)
    }

    func testCommandNTakesTheOpenWindowsLayoutButNotItsTabs() {
        let snapshot = WorkspaceRegistry.snapshotForNewWindow(last: nil, focused: last, paneSetting: 0)
        XCTAssertEqual(snapshot?.paneCount, 3)
        XCTAssertEqual(snapshot?.showSidebar, false)
        XCTAssertEqual(snapshot?.paneFractions, [2, 1, 1])
        XCTAssertTrue(snapshot?.panes.isEmpty ?? false)
        XCTAssertNil(snapshot?.tint)
    }

    func testLayoutRoundTripsThroughTheWorkspace() {
        let workspace = WorkspaceState(snapshot: last)
        XCTAssertEqual(workspace.paneCount, 3)
        XCTAssertFalse(workspace.showSidebar)
        XCTAssertEqual(workspace.paneFractions, [2, 1, 1])
        XCTAssertEqual(workspace.snapshot.paneFractions, [2, 1, 1])
        XCTAssertEqual(workspace.snapshot.showSidebar, false)
    }

    func testSessionsSavedBeforeThisStillDecode() throws {
        let old = #"{"panes":[],"paneCount":3,"activePane":0,"showInspector":false}"#
        let snapshot = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(old.utf8))
        let workspace = WorkspaceState(snapshot: snapshot)
        XCTAssertEqual(workspace.paneCount, 3)
        XCTAssertTrue(workspace.showSidebar)
        XCTAssertEqual(workspace.paneFractions, [1, 1, 1])
    }
}

@MainActor
final class WindowLayoutTests: XCTestCase {
    func testMinimumWidthCoversEverythingShown() {
        // 3 panes × 240 + 4 gaps + sidebar 230 + inspector 270.
        XCTAssertEqual(WindowLayout.minimumWidth(panes: 3, sidebar: true, inspector: true), 1260)
        XCTAssertEqual(WindowLayout.minimumWidth(panes: 2, sidebar: true, inspector: true), 1010)
        XCTAssertEqual(WindowLayout.minimumWidth(panes: 3, sidebar: true, inspector: false), 990)
        XCTAssertEqual(WindowLayout.minimumWidth(panes: 1, sidebar: false, inspector: false), WindowLayout.floor)
    }

    func testWideningGrowsRightThenSlidesLeftAtTheScreenEdge() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let grown = WindowLayout.widened(NSRect(x: 100, y: 50, width: 900, height: 600), to: 1260, within: screen)
        XCTAssertEqual(grown, NSRect(x: 100, y: 50, width: 1260, height: 600))

        let slid = WindowLayout.widened(NSRect(x: 400, y: 50, width: 900, height: 600), to: 1260, within: screen)
        XCTAssertEqual(slid.maxX, 1440)
        XCTAssertEqual(slid.width, 1260)

        let capped = WindowLayout.widened(NSRect(x: 0, y: 0, width: 900, height: 600), to: 2000, within: screen)
        XCTAssertEqual(capped.width, 1440)

        let wide = NSRect(x: 0, y: 0, width: 1300, height: 600)
        XCTAssertEqual(WindowLayout.widened(wide, to: 1260, within: screen), wide, "already wide enough: untouched")
    }
}

@MainActor
final class DeckTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID()

    private func target(_ panes: [UUID], sidebar: Bool = true, inspector: Bool = false) -> DeckTarget {
        DeckTarget(sidebar: sidebar, inspector: inspector, inspectorWidth: 300, panes: panes,
                   fractions: Array(repeating: 1, count: panes.count))
    }

    func testSettledLayoutFillsTheWindowExactly() {
        let t = target([a, b], inspector: true)
        let geometry = DeckGeometry.layout(DeckGeometry.pose(of: t, width: 1400), order: t.panes, width: 1400)
        XCTAssertEqual(geometry.sidebarX, 10)
        XCTAssertEqual(geometry.panes[0].x, 240, "sidebar card (10 + 220) plus a 10pt margin")
        let last = geometry.panes[1]
        XCTAssertEqual(last.x + last.width, 1400 - 310 - 10, accuracy: 0.001, "panes end 10pt before the inspector card")
        XCTAssertEqual(geometry.inspectorX, 1090, accuracy: 0.001)
        XCTAssertEqual(geometry.panes[1].x - (geometry.panes[0].x + geometry.panes[0].width), 10, accuracy: 0.001)
    }

    func testHalfwayInspectorSharesTheMovementWithThePanes() {
        let closed = DeckGeometry.pose(of: target([a, b]), width: 1400)
        let open = DeckGeometry.pose(of: target([a, b], inspector: true), width: 1400)
        let half = DeckGeometry.layout(DeckPose.blend(closed, open, 0.5), order: [a, b], width: 1400)
        XCTAssertEqual(half.inspectorX, 1400 - 155, accuracy: 0.001, "card keeps its width and slides in")
        XCTAssertEqual(half.panes[1].x + half.panes[1].width, half.inspectorX - 10, accuracy: 0.001, "no overlap mid-flight")
    }

    func testArrivingPaneBringsItsGapAndNeverOverlaps() {
        let two = DeckGeometry.pose(of: target([a, b]), width: 1400)
        let three = DeckGeometry.pose(of: target([a, b, c]), width: 1400)
        for step in stride(from: 0.0, through: 1.0, by: 0.1) {
            let geometry = DeckGeometry.layout(DeckPose.blend(two, three, CGFloat(step)), order: [a, b, c], width: 1400)
            for (left, right) in zip(geometry.panes, geometry.panes.dropFirst()) {
                XCTAssertLessThanOrEqual(left.x + left.width, right.x + 0.001)
            }
            let end = geometry.panes.last.map { $0.x + $0.width } ?? 0
            XCTAssertEqual(end, 1390, accuracy: 0.001, "the row always reaches the right margin")
        }
        let start = DeckGeometry.layout(two, order: [a, b, c], width: 1400)
        XCTAssertEqual(start.panes[2].width, 0, accuracy: 0.001, "starts with no width")
    }

    func testLeavingPanesKeepTheirPlace() {
        XCTAssertEqual(DeckAnimator.merge([a, b, c], into: [a, c]), [a, b, c])
        XCTAssertEqual(DeckAnimator.merge([a, b, c], into: [b, c]), [a, b, c])
        XCTAssertEqual(DeckAnimator.merge([a, b], into: [a, b, c]), [a, b, c])
        XCTAssertEqual(DeckAnimator.merge([a, b, c], into: [a]), [a, b, c])
    }

    func testSpringStartsAtRestAndSettlesWithoutOvershoot() {
        XCTAssertEqual(DeckGeometry.ease(0), 0)
        var previous: CGFloat = 0
        for step in 1...50 {
            let value = DeckGeometry.ease(Double(step) * 0.01)
            XCTAssertGreaterThanOrEqual(value, previous)
            XCTAssertLessThanOrEqual(value, 1)
            previous = value
        }
        XCTAssertGreaterThan(DeckGeometry.ease(DeckGeometry.duration), 0.995, "nothing visible left when it snaps to 1")
    }
}

final class ColumnFitTests: XCTestCase {
    private let widths: [String: CGFloat] = ["modified": 124, "size": 118, "kind": 110]

    func testNarrowListDropsLeastImportantFirst() {
        let all: Set<String> = ["modified", "size", "kind"]
        XCTAssertEqual(FileScrollView.fittingColumns(desired: all, widths: widths, autoHidden: [], width: 600, spacing: 6), all)
        XCTAssertEqual(FileScrollView.fittingColumns(desired: all, widths: widths, autoHidden: [], width: 470, spacing: 6),
                       ["modified", "size"])
        XCTAssertEqual(FileScrollView.fittingColumns(desired: all, widths: widths, autoHidden: [], width: 340, spacing: 6),
                       ["modified"])
        XCTAssertEqual(FileScrollView.fittingColumns(desired: all, widths: widths, autoHidden: [], width: 250, spacing: 6), [])
    }

    func testHiddenColumnNeedsExtraRoomToComeBack() {
        let wants: Set<String> = ["modified", "size"]
        // 470pt: room for both when "size" is showing, but not enough to bring it back once auto-hidden.
        XCTAssertEqual(FileScrollView.fittingColumns(desired: wants, widths: widths, autoHidden: [], width: 470, spacing: 6), wants)
        XCTAssertEqual(FileScrollView.fittingColumns(desired: wants, widths: widths, autoHidden: ["size"], width: 470, spacing: 6),
                       ["modified"])
    }

    func testColumnsShrinkAwayAndGrowInInsteadOfPopping() {
        XCTAssertEqual(FileScrollView.blendedWidth(full: 120, inStart: true, inTarget: true, progress: 0.5), 120)
        XCTAssertEqual(FileScrollView.blendedWidth(full: 120, inStart: true, inTarget: false, progress: 0.25), 90)
        XCTAssertNil(FileScrollView.blendedWidth(full: 120, inStart: true, inTarget: false, progress: 1), "gone at the end")
        XCTAssertEqual(FileScrollView.blendedWidth(full: 120, inStart: false, inTarget: true, progress: 0.5), 60)
        XCTAssertNil(FileScrollView.blendedWidth(full: 120, inStart: false, inTarget: true, progress: 0), "not there yet")
        XCTAssertNil(FileScrollView.blendedWidth(full: 120, inStart: false, inTarget: false, progress: 0.5))
    }
}
