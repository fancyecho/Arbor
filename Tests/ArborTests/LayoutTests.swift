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
