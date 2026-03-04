import ApplicationServices
import Foundation
import Testing

@testable import OmniWM

private func makeHandle(id: UUID, pid: pid_t) -> WindowHandle {
    WindowHandle(
        id: id,
        pid: pid,
        axElement: AXUIElementCreateSystemWide()
    )
}

private func assertRuntimeMatchesSnapshot(
    engine: NiriLayoutEngine,
    workspaceId: WorkspaceDescriptor.ID
) {
    guard let context = engine.ensureLayoutContext(for: workspaceId) else {
        #expect(Bool(false), "expected layout context for runtime export")
        return
    }

    let exported = NiriStateZigKernel.exportRuntimeState(context: context)
    #expect(exported.rc == 0)

    let snapshot = NiriStateZigKernel.makeSnapshot(columns: engine.columns(in: workspaceId))
    #expect(exported.export.columns.count == snapshot.columns.count)
    #expect(exported.export.windows.count == snapshot.windows.count)

    for (idx, runtimeColumn) in exported.export.columns.enumerated() {
        let snapshotColumn = snapshot.columns[idx]
        #expect(runtimeColumn.columnId.uuid == NiriStateZigKernel.uuid(from: snapshotColumn.column_id))
        #expect(runtimeColumn.windowStart == snapshotColumn.window_start)
        #expect(runtimeColumn.windowCount == snapshotColumn.window_count)
        #expect(runtimeColumn.activeTileIdx == snapshotColumn.active_tile_idx)
        #expect(runtimeColumn.isTabbed == (snapshotColumn.is_tabbed != 0))
    }

    for (idx, runtimeWindow) in exported.export.windows.enumerated() {
        let snapshotWindow = snapshot.windows[idx]
        #expect(runtimeWindow.windowId.uuid == NiriStateZigKernel.uuid(from: snapshotWindow.window_id))
        #expect(runtimeWindow.columnId.uuid == NiriStateZigKernel.uuid(from: snapshotWindow.column_id))
        #expect(runtimeWindow.columnIndex == snapshotWindow.column_index)
    }
}

@Suite struct NiriZigRuntimeProjectorTests {
    @Test func projectorReordersColumnsAndWindowsAndReusesNodeIdentity() {
        let workspaceId = WorkspaceDescriptor.ID()
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 4, maxVisibleColumns: 3)
        let root = engine.ensureRoot(for: workspaceId)

        let firstColumn = root.columns[0]
        let secondColumn = NiriContainer()
        root.appendChild(secondColumn)

        let h1 = makeHandle(id: UUID(), pid: 1001)
        let h2 = makeHandle(id: UUID(), pid: 1002)
        let h3 = makeHandle(id: UUID(), pid: 1003)
        let h4 = makeHandle(id: UUID(), pid: 1004)

        let w1 = NiriWindow(handle: h1)
        let w2 = NiriWindow(handle: h2)
        let w3 = NiriWindow(handle: h3)
        let w4 = NiriWindow(handle: h4)

        firstColumn.appendChild(w1)
        firstColumn.appendChild(w2)
        secondColumn.appendChild(w3)
        secondColumn.appendChild(w4)

        engine.handleToNode[h1] = w1
        engine.handleToNode[h2] = w2
        engine.handleToNode[h3] = w3
        engine.handleToNode[h4] = w4

        let export = NiriStateZigKernel.RuntimeStateExport(
            columns: [
                .init(
                    columnId: secondColumn.id,
                    windowStart: 0,
                    windowCount: 2,
                    activeTileIdx: 0,
                    isTabbed: false,
                    sizeValue: Double(secondColumn.size)
                ),
                .init(
                    columnId: firstColumn.id,
                    windowStart: 2,
                    windowCount: 2,
                    activeTileIdx: 0,
                    isTabbed: false,
                    sizeValue: Double(firstColumn.size)
                ),
            ],
            windows: [
                .init(windowId: w4.id, columnId: secondColumn.id, columnIndex: 0, sizeValue: Double(w4.size)),
                .init(windowId: w3.id, columnId: secondColumn.id, columnIndex: 0, sizeValue: Double(w3.size)),
                .init(windowId: w2.id, columnId: firstColumn.id, columnIndex: 1, sizeValue: Double(w2.size)),
                .init(windowId: w1.id, columnId: firstColumn.id, columnIndex: 1, sizeValue: Double(w1.size)),
            ]
        )

        let result = NiriStateZigRuntimeProjector.project(
            export: export,
            workspaceId: workspaceId,
            engine: engine
        )
        #expect(result.applied)

        let columns = engine.columns(in: workspaceId)
        #expect(columns.count == 2)
        #expect(columns[0].id == secondColumn.id)
        #expect(columns[1].id == firstColumn.id)

        #expect(columns[0].windowNodes.count == 2)
        #expect(columns[0].windowNodes[0] === w4)
        #expect(columns[0].windowNodes[1] === w3)

        #expect(columns[1].windowNodes.count == 2)
        #expect(columns[1].windowNodes[0] === w2)
        #expect(columns[1].windowNodes[1] === w1)

        #expect(engine.findNode(by: w1.id) === w1)
        #expect(engine.findNode(by: w4.id) === w4)
    }

    @Test func projectorFallsBackToWindowHandleIdWhenNodeIdDoesNotMatch() {
        let workspaceId = WorkspaceDescriptor.ID()
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 4, maxVisibleColumns: 3)
        let root = engine.ensureRoot(for: workspaceId)
        let column = root.columns[0]

        let handleId = UUID()
        let mismatchedNodeId = NodeId(uuid: UUID())
        let handle = makeHandle(id: handleId, pid: 2001)
        let window = NiriWindow(handle: handle, id: mismatchedNodeId)
        column.appendChild(window)
        engine.handleToNode[handle] = window

        let export = NiriStateZigKernel.RuntimeStateExport(
            columns: [
                .init(
                    columnId: column.id,
                    windowStart: 0,
                    windowCount: 1,
                    activeTileIdx: 0,
                    isTabbed: false,
                    sizeValue: Double(column.size)
                )
            ],
            windows: [
                .init(
                    windowId: NodeId(uuid: handleId),
                    columnId: column.id,
                    columnIndex: 0,
                    sizeValue: Double(window.size)
                )
            ]
        )

        let result = NiriStateZigRuntimeProjector.project(
            export: export,
            workspaceId: workspaceId,
            engine: engine
        )
        #expect(result.applied)
        #expect(column.windowNodes.count == 1)
        #expect(column.windowNodes[0] === window)
        #expect(column.windowNodes[0].id == mismatchedNodeId)
        #expect(column.windowNodes[0].id.uuid != handleId)
    }

    @Test func projectorCreatesMissingNodesWithExplicitIdsAndPrunesStaleState() {
        let workspaceId = WorkspaceDescriptor.ID()
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 4, maxVisibleColumns: 3)
        let root = engine.ensureRoot(for: workspaceId)
        let oldColumn = root.columns[0]

        let oldHandle = makeHandle(id: UUID(), pid: 3001)
        let oldWindow = NiriWindow(handle: oldHandle)
        oldColumn.appendChild(oldWindow)
        engine.handleToNode[oldHandle] = oldWindow

        let newWindowId = UUID()
        let newHandle = makeHandle(id: newWindowId, pid: 3002)
        let detached = NiriWindow(handle: newHandle)
        engine.handleToNode[newHandle] = detached

        let newColumnId = NodeId(uuid: UUID())
        let export = NiriStateZigKernel.RuntimeStateExport(
            columns: [
                .init(
                    columnId: newColumnId,
                    windowStart: 0,
                    windowCount: 1,
                    activeTileIdx: 0,
                    isTabbed: false,
                    sizeValue: 1.0
                )
            ],
            windows: [
                .init(
                    windowId: NodeId(uuid: newWindowId),
                    columnId: newColumnId,
                    columnIndex: 0,
                    sizeValue: 1.0
                )
            ]
        )

        let result = NiriStateZigRuntimeProjector.project(
            export: export,
            workspaceId: workspaceId,
            engine: engine
        )
        #expect(result.applied)

        let columns = engine.columns(in: workspaceId)
        #expect(columns.count == 1)
        #expect(columns[0].id == newColumnId)
        #expect(columns[0] !== oldColumn)

        #expect(columns[0].windowNodes.count == 1)
        let projectedWindow = columns[0].windowNodes[0]
        #expect(projectedWindow.handle === newHandle)
        #expect(projectedWindow.id.uuid == newWindowId)

        #expect(engine.handleToNode[oldHandle] == nil)
        #expect(engine.handleToNode[newHandle] === projectedWindow)
    }

    @Test func projectorAppliesUiHintsForTabRefreshAndCachedWidthReset() {
        let workspaceId = WorkspaceDescriptor.ID()
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 4, maxVisibleColumns: 3)
        let root = engine.ensureRoot(for: workspaceId)
        let column = root.columns[0]

        let h1 = makeHandle(id: UUID(), pid: 4001)
        let h2 = makeHandle(id: UUID(), pid: 4002)
        let w1 = NiriWindow(handle: h1)
        let w2 = NiriWindow(handle: h2)
        column.appendChild(w1)
        column.appendChild(w2)
        engine.handleToNode[h1] = w1
        engine.handleToNode[h2] = w2

        column.displayMode = .tabbed
        column.setActiveTileIdx(0)
        engine.updateTabbedColumnVisibility(column: column)
        column.cachedWidth = 420

        let export = NiriStateZigKernel.RuntimeStateExport(
            columns: [
                .init(
                    columnId: column.id,
                    windowStart: 0,
                    windowCount: 2,
                    activeTileIdx: 1,
                    isTabbed: true,
                    sizeValue: Double(column.size)
                )
            ],
            windows: [
                .init(windowId: w1.id, columnId: column.id, columnIndex: 0, sizeValue: Double(w1.size)),
                .init(windowId: w2.id, columnId: column.id, columnIndex: 0, sizeValue: Double(w2.size)),
            ]
        )

        let hints = NiriStateZigKernel.RuntimeMutationHints(
            refreshTabbedVisibilityColumnIds: [column.id],
            resetAllColumnCachedWidths: true,
            delegatedMoveColumn: nil
        )

        let result = NiriStateZigRuntimeProjector.project(
            export: export,
            hints: hints,
            workspaceId: workspaceId,
            engine: engine
        )
        #expect(result.applied)

        #expect(column.activeTileIdx == 1)
        #expect(column.cachedWidth == 0)
        #expect(w1.isHiddenInTabbedMode)
        #expect(!w2.isHiddenInTabbedMode)
    }

    @Test func projectorFailsWhenRuntimeWindowHandleCannotBeResolved() {
        let workspaceId = WorkspaceDescriptor.ID()
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 4, maxVisibleColumns: 3)
        let root = engine.ensureRoot(for: workspaceId)
        let originalColumnId = root.columns[0].id

        let missingWindowId = NodeId(uuid: UUID())
        let export = NiriStateZigKernel.RuntimeStateExport(
            columns: [
                .init(
                    columnId: originalColumnId,
                    windowStart: 0,
                    windowCount: 1,
                    activeTileIdx: 0,
                    isTabbed: false,
                    sizeValue: 1.0
                )
            ],
            windows: [
                .init(
                    windowId: missingWindowId,
                    columnId: originalColumnId,
                    columnIndex: 0,
                    sizeValue: 1.0
                )
            ]
        )

        let result = NiriStateZigRuntimeProjector.project(
            export: export,
            workspaceId: workspaceId,
            engine: engine
        )
        #expect(!result.applied)
        #expect(result.failureReason != nil)
    }

    @Test func projectorResolvesMissingHandleFromAdditionalHandleMap() {
        let workspaceId = WorkspaceDescriptor.ID()
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 4, maxVisibleColumns: 3)
        let root = engine.ensureRoot(for: workspaceId)
        let column = root.columns[0]

        let incomingWindowUUID = UUID()
        let incomingHandle = makeHandle(id: incomingWindowUUID, pid: 4501)
        let export = NiriStateZigKernel.RuntimeStateExport(
            columns: [
                .init(
                    columnId: column.id,
                    windowStart: 0,
                    windowCount: 1,
                    activeTileIdx: 0,
                    isTabbed: false,
                    sizeValue: 1.0
                )
            ],
            windows: [
                .init(
                    windowId: NodeId(uuid: incomingWindowUUID),
                    columnId: column.id,
                    columnIndex: 0,
                    sizeValue: 1.0
                )
            ]
        )

        let result = NiriStateZigRuntimeProjector.project(
            export: export,
            workspaceId: workspaceId,
            engine: engine,
            additionalHandlesById: [incomingWindowUUID: incomingHandle]
        )
        #expect(result.applied)
        #expect(column.windowNodes.count == 1)
        #expect(column.windowNodes[0].handle === incomingHandle)
        #expect(column.windowNodes[0].id.uuid == incomingWindowUUID)
        #expect(engine.handleToNode[incomingHandle] === column.windowNodes[0])
    }

    @Test func eagerSyncHooksKeepRuntimeExportCoherent() {
        let workspaceId = WorkspaceDescriptor.ID()
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 4, maxVisibleColumns: 3)
        let root = engine.ensureRoot(for: workspaceId)
        let column = root.columns[0]

        let h1 = makeHandle(id: UUID(), pid: 5001)
        let h2 = makeHandle(id: UUID(), pid: 5002)
        let w1 = NiriWindow(handle: h1)
        let w2 = NiriWindow(handle: h2)
        column.appendChild(w1)
        column.appendChild(w2)
        engine.handleToNode[h1] = w1
        engine.handleToNode[h2] = w2

        #expect(engine.syncRuntimeStateNow(workspaceId: workspaceId))
        assertRuntimeMatchesSnapshot(engine: engine, workspaceId: workspaceId)

        #expect(engine.setColumnDisplay(.tabbed, for: column))
        assertRuntimeMatchesSnapshot(engine: engine, workspaceId: workspaceId)

        #expect(engine.activateTab(at: 1, in: column))
        assertRuntimeMatchesSnapshot(engine: engine, workspaceId: workspaceId)

        var state = ViewportState()
        column.cachedWidth = 500
        engine.toggleColumnWidth(
            column,
            forwards: true,
            in: workspaceId,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            gaps: 8
        )
        assertRuntimeMatchesSnapshot(engine: engine, workspaceId: workspaceId)

        #expect(
            engine.interactiveResizeBegin(
                windowId: w1.id,
                edges: [.left],
                startLocation: .zero,
                in: workspaceId
            )
        )
        let changed = engine.interactiveResizeUpdate(
            currentLocation: CGPoint(x: 40, y: 0),
            monitorFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            gaps: LayoutGaps(horizontal: 8, vertical: 8, outer: .zero)
        )
        #expect(changed)
        assertRuntimeMatchesSnapshot(engine: engine, workspaceId: workspaceId)
    }
}
