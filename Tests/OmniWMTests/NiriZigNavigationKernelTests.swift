import Foundation
import Testing

@testable import OmniWM

private let omniOK: Int32 = 0
private let omniErrOutOfRange: Int32 = -2

private struct NavigationFixture {
    let engine: NiriLayoutEngine
    let workspaceId: WorkspaceDescriptor.ID
    let columns: [NiriContainer]
    let windowsByColumn: [[NiriWindow]]
}

private func makeNavigationFixture(tabbedSecondColumn: Bool = false) -> NavigationFixture {
    let engine = NiriLayoutEngine(maxWindowsPerColumn: 8)
    let workspaceId = WorkspaceDescriptor.ID()
    let root = NiriRoot(workspaceId: workspaceId)
    engine.roots[workspaceId] = root

    var columns: [NiriContainer] = []
    var windowsByColumn: [[NiriWindow]] = []

    for columnIndex in 0 ..< 2 {
        let column = NiriContainer()
        if tabbedSecondColumn, columnIndex == 1 {
            column.displayMode = .tabbed
        }
        root.appendChild(column)
        columns.append(column)

        var windows: [NiriWindow] = []
        for rowIndex in 0 ..< 3 {
            let handle = makeTestHandle(pid: pid_t(30_000 + columnIndex * 100 + rowIndex))
            let window = NiriWindow(handle: handle)
            column.appendChild(window)
            engine.handleToNode[handle] = window
            windows.append(window)
        }

        if columnIndex == 1 {
            column.setActiveTileIdx(tabbedSecondColumn ? 1 : 2)
        } else {
            column.setActiveTileIdx(0)
        }
        windowsByColumn.append(windows)
    }

    return NavigationFixture(
        engine: engine,
        workspaceId: workspaceId,
        columns: columns,
        windowsByColumn: windowsByColumn
    )
}

@Suite struct NiriZigNavigationKernelTests {
    @Test func moveByColumnsResolvesTargetAndUpdatesSourceActiveTile() {
        let fixture = makeNavigationFixture()
        let snapshot = NiriStateZigKernel.makeSnapshot(columns: fixture.engine.columns(in: fixture.workspaceId))

        let current = fixture.windowsByColumn[0][1]
        let selection = NiriStateZigKernel.makeSelectionContext(node: current, snapshot: snapshot)
        #expect(selection != nil)

        let request = NiriStateZigKernel.NavigationRequest(
            op: .moveByColumns,
            selection: selection,
            step: 1
        )

        let outcome = NiriStateZigKernel.resolveNavigation(snapshot: snapshot, request: request)

        #expect(outcome.rc == omniOK)
        #expect(outcome.hasTarget)
        #expect(outcome.result.update_source_active_tile == 1)
        #expect(outcome.result.source_column_index == 0)
        #expect(outcome.result.source_active_tile_idx == 1)

        let targetIndex = outcome.targetWindowIndex
        #expect(targetIndex != nil)
        if let targetIndex {
            let target = snapshot.windowEntries[targetIndex].window
            #expect(target.id == fixture.windowsByColumn[1][2].id)
        }
    }

    @Test func rejectsInvalidSelectedWindowIndex() {
        let fixture = makeNavigationFixture()
        let snapshot = NiriStateZigKernel.makeSnapshot(columns: fixture.engine.columns(in: fixture.workspaceId))

        let current = fixture.windowsByColumn[0][0]
        let selection = NiriStateZigKernel.makeSelectionContext(node: current, snapshot: snapshot)
        #expect(selection != nil)
        guard let selection else { return }

        let request = NiriStateZigKernel.NavigationRequest(
            op: .moveByColumns,
            selection: NiriStateZigKernel.SelectionContext(
                selectedWindowIndex: snapshot.windows.count,
                selectedColumnIndex: selection.selectedColumnIndex,
                selectedRowIndex: selection.selectedRowIndex
            ),
            step: 1
        )

        let outcome = NiriStateZigKernel.resolveNavigation(snapshot: snapshot, request: request)
        #expect(outcome.rc == omniErrOutOfRange)
        #expect(!outcome.hasTarget)
    }

    @Test func rejectsOutOfRangeFocusWindowIndex() {
        let fixture = makeNavigationFixture()
        let snapshot = NiriStateZigKernel.makeSnapshot(columns: fixture.engine.columns(in: fixture.workspaceId))

        let current = fixture.windowsByColumn[0][0]
        let selection = NiriStateZigKernel.makeSelectionContext(node: current, snapshot: snapshot)

        let request = NiriStateZigKernel.NavigationRequest(
            op: .focusWindowIndex,
            selection: selection,
            targetWindowIndex: 99
        )

        let outcome = NiriStateZigKernel.resolveNavigation(snapshot: snapshot, request: request)
        #expect(outcome.rc == omniErrOutOfRange)
        #expect(!outcome.hasTarget)
    }

    @Test func tabbedVerticalMoveRequestsVisibilityRefresh() {
        let fixture = makeNavigationFixture(tabbedSecondColumn: true)
        let snapshot = NiriStateZigKernel.makeSnapshot(columns: fixture.engine.columns(in: fixture.workspaceId))

        let current = fixture.windowsByColumn[1][0]
        let selection = NiriStateZigKernel.makeSelectionContext(node: current, snapshot: snapshot)

        let request = NiriStateZigKernel.NavigationRequest(
            op: .moveVertical,
            selection: selection,
            direction: .up,
            orientation: .horizontal
        )

        let outcome = NiriStateZigKernel.resolveNavigation(snapshot: snapshot, request: request)

        #expect(outcome.rc == omniOK)
        #expect(outcome.hasTarget)
        #expect(outcome.result.update_target_active_tile == 1)
        #expect(outcome.result.target_column_index == 1)
        #expect(outcome.result.target_active_tile_idx == 2)
        #expect(outcome.result.refresh_tabbed_visibility_target == 1)

        let targetIndex = outcome.targetWindowIndex
        #expect(targetIndex != nil)
        if let targetIndex {
            let target = snapshot.windowEntries[targetIndex].window
            #expect(target.id == fixture.windowsByColumn[1][2].id)
        }
    }
}
