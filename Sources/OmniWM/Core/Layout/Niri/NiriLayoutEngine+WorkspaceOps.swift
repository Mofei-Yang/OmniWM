import AppKit
import Foundation

extension NiriLayoutEngine {
    private struct WorkspacePreparedRequest {
        let sourceWorkspaceId: WorkspaceDescriptor.ID
        let targetWorkspaceId: WorkspaceDescriptor.ID
        let sourceSnapshot: NiriStateZigKernel.Snapshot
        let targetSnapshot: NiriStateZigKernel.Snapshot
        let request: NiriStateZigKernel.WorkspaceRequest
    }

    private struct WorkspaceApplyOutcome {
        let applied: Bool
        let newSourceFocusNodeId: NodeId?
        let targetSelectionNodeId: NodeId?
        let movedHandle: WindowHandle?
    }

    struct WorkspaceMoveResult {
        let newFocusNodeId: NodeId?

        let movedHandle: WindowHandle?

        let targetWorkspaceId: WorkspaceDescriptor.ID
    }

    private func applyRuntimeWorkspaceMutation(
        _ prepared: WorkspacePreparedRequest,
        targetCreatedColumnId: UUID?,
        sourcePlaceholderColumnId: UUID?
    ) -> WorkspaceApplyOutcome? {
        guard let sourceContext = ensureLayoutContext(for: prepared.sourceWorkspaceId),
              let targetContext = ensureLayoutContext(for: prepared.targetWorkspaceId)
        else {
            return nil
        }

        let sourceSeedRC = NiriStateZigKernel.seedRuntimeState(
            context: sourceContext,
            snapshot: prepared.sourceSnapshot
        )
        guard sourceSeedRC == 0 else {
            return nil
        }
        runtimeMirrorStates[prepared.sourceWorkspaceId] = RuntimeMirrorState(
            isSeeded: true,
            columnCount: prepared.sourceSnapshot.columns.count,
            windowCount: prepared.sourceSnapshot.windows.count
        )

        let targetSeedRC = NiriStateZigKernel.seedRuntimeState(
            context: targetContext,
            snapshot: prepared.targetSnapshot
        )
        guard targetSeedRC == 0 else {
            return nil
        }
        runtimeMirrorStates[prepared.targetWorkspaceId] = RuntimeMirrorState(
            isSeeded: true,
            columnCount: prepared.targetSnapshot.columns.count,
            windowCount: prepared.targetSnapshot.windows.count
        )

        let applyOutcome = NiriStateZigKernel.applyWorkspace(
            sourceContext: sourceContext,
            targetContext: targetContext,
            request: .init(
                request: prepared.request,
                targetCreatedColumnId: targetCreatedColumnId,
                sourcePlaceholderColumnId: sourcePlaceholderColumnId
            )
        )
        guard applyOutcome.rc == 0 else {
            return nil
        }
        guard applyOutcome.applied else {
            return WorkspaceApplyOutcome(
                applied: false,
                newSourceFocusNodeId: nil,
                targetSelectionNodeId: nil,
                movedHandle: nil
            )
        }

        let sourceExport = NiriStateZigKernel.exportRuntimeState(context: sourceContext)
        guard sourceExport.rc == 0 else {
            return nil
        }

        let targetExport = NiriStateZigKernel.exportRuntimeState(context: targetContext)
        guard targetExport.rc == 0 else {
            return nil
        }

        let targetProjection = NiriStateZigRuntimeProjector.project(
            export: targetExport.export,
            workspaceId: prepared.targetWorkspaceId,
            engine: self
        )
        guard targetProjection.applied else {
            return nil
        }

        let sourceProjection = NiriStateZigRuntimeProjector.project(
            export: sourceExport.export,
            workspaceId: prepared.sourceWorkspaceId,
            engine: self
        )
        guard sourceProjection.applied else {
            return nil
        }

        let movedHandle: WindowHandle?
        if let movedWindowId = applyOutcome.movedWindowId {
            guard let movedWindow = root(for: prepared.targetWorkspaceId)?
                .findNode(by: movedWindowId) as? NiriWindow
            else {
                return nil
            }
            movedHandle = movedWindow.handle
        } else {
            movedHandle = nil
        }

        let sourceProjectedSnapshot = NiriStateZigKernel.makeSnapshot(
            columns: columns(in: prepared.sourceWorkspaceId)
        )
        let targetProjectedSnapshot = NiriStateZigKernel.makeSnapshot(
            columns: columns(in: prepared.targetWorkspaceId)
        )

        runtimeMirrorStates[prepared.sourceWorkspaceId] = RuntimeMirrorState(
            isSeeded: true,
            columnCount: sourceProjectedSnapshot.columns.count,
            windowCount: sourceProjectedSnapshot.windows.count
        )
        runtimeMirrorStates[prepared.targetWorkspaceId] = RuntimeMirrorState(
            isSeeded: true,
            columnCount: targetProjectedSnapshot.columns.count,
            windowCount: targetProjectedSnapshot.windows.count
        )

        return WorkspaceApplyOutcome(
            applied: true,
            newSourceFocusNodeId: applyOutcome.sourceSelectionWindowId,
            targetSelectionNodeId: applyOutcome.targetSelectionWindowId,
            movedHandle: movedHandle
        )
    }

    private func executePreparedWorkspaceMutation(
        _ prepared: WorkspacePreparedRequest,
        targetCreatedColumnId: UUID? = nil,
        sourcePlaceholderColumnId: UUID? = nil
    ) -> WorkspaceApplyOutcome? {
        applyRuntimeWorkspaceMutation(
            prepared,
            targetCreatedColumnId: targetCreatedColumnId,
            sourcePlaceholderColumnId: sourcePlaceholderColumnId
        )
    }

    private func prepareMoveWindowToWorkspaceRequest(
        _ window: NiriWindow,
        from sourceWorkspaceId: WorkspaceDescriptor.ID,
        to targetWorkspaceId: WorkspaceDescriptor.ID
    ) -> WorkspacePreparedRequest? {
        guard sourceWorkspaceId != targetWorkspaceId else { return nil }

        guard let sourceRoot = roots[sourceWorkspaceId],
              findColumn(containing: window, in: sourceWorkspaceId) != nil
        else {
            return nil
        }

        let targetRoot = ensureRoot(for: targetWorkspaceId)
        let sourceSnapshot = NiriStateZigKernel.makeSnapshot(columns: sourceRoot.columns)
        let targetSnapshot = NiriStateZigKernel.makeSnapshot(columns: targetRoot.columns)
        guard let sourceWindowIndex = sourceSnapshot.windowIndexByNodeId[window.id] else {
            return nil
        }

        let request = NiriStateZigKernel.WorkspaceRequest(
            op: .moveWindowToWorkspace,
            sourceWindowIndex: sourceWindowIndex,
            maxVisibleColumns: maxVisibleColumns
        )

        return WorkspacePreparedRequest(
            sourceWorkspaceId: sourceWorkspaceId,
            targetWorkspaceId: targetWorkspaceId,
            sourceSnapshot: sourceSnapshot,
            targetSnapshot: targetSnapshot,
            request: request
        )
    }

    private func prepareMoveColumnToWorkspaceRequest(
        _ column: NiriContainer,
        from sourceWorkspaceId: WorkspaceDescriptor.ID,
        to targetWorkspaceId: WorkspaceDescriptor.ID
    ) -> WorkspacePreparedRequest? {
        guard sourceWorkspaceId != targetWorkspaceId else { return nil }

        guard let sourceRoot = roots[sourceWorkspaceId],
              columnIndex(of: column, in: sourceWorkspaceId) != nil
        else {
            return nil
        }

        let targetRoot = ensureRoot(for: targetWorkspaceId)
        let sourceSnapshot = NiriStateZigKernel.makeSnapshot(columns: sourceRoot.columns)
        let targetSnapshot = NiriStateZigKernel.makeSnapshot(columns: targetRoot.columns)
        guard let sourceColumnIndex = sourceSnapshot.columnIndexByNodeId[column.id] else {
            return nil
        }

        let request = NiriStateZigKernel.WorkspaceRequest(
            op: .moveColumnToWorkspace,
            sourceColumnIndex: sourceColumnIndex
        )

        return WorkspacePreparedRequest(
            sourceWorkspaceId: sourceWorkspaceId,
            targetWorkspaceId: targetWorkspaceId,
            sourceSnapshot: sourceSnapshot,
            targetSnapshot: targetSnapshot,
            request: request
        )
    }

    func moveWindowToWorkspace(
        _ window: NiriWindow,
        from sourceWorkspaceId: WorkspaceDescriptor.ID,
        to targetWorkspaceId: WorkspaceDescriptor.ID,
        sourceState: inout ViewportState,
        targetState: inout ViewportState
    ) -> WorkspaceMoveResult? {
        guard let prepared = prepareMoveWindowToWorkspaceRequest(
            window,
            from: sourceWorkspaceId,
            to: targetWorkspaceId
        ) else {
            return nil
        }

        guard let applyOutcome = executePreparedWorkspaceMutation(
            prepared,
            targetCreatedColumnId: UUID(),
            sourcePlaceholderColumnId: UUID()
        ) else {
            return nil
        }
        guard applyOutcome.applied else {
            return nil
        }

        sourceState.selectedNodeId = applyOutcome.newSourceFocusNodeId
        targetState.selectedNodeId = applyOutcome.targetSelectionNodeId

        return WorkspaceMoveResult(
            newFocusNodeId: applyOutcome.newSourceFocusNodeId,
            movedHandle: applyOutcome.movedHandle,
            targetWorkspaceId: targetWorkspaceId
        )
    }

    func moveColumnToWorkspace(
        _ column: NiriContainer,
        from sourceWorkspaceId: WorkspaceDescriptor.ID,
        to targetWorkspaceId: WorkspaceDescriptor.ID,
        sourceState: inout ViewportState,
        targetState: inout ViewportState
    ) -> WorkspaceMoveResult? {
        guard let prepared = prepareMoveColumnToWorkspaceRequest(
            column,
            from: sourceWorkspaceId,
            to: targetWorkspaceId
        ) else {
            return nil
        }

        guard let applyOutcome = executePreparedWorkspaceMutation(
            prepared,
            sourcePlaceholderColumnId: UUID()
        ) else {
            return nil
        }
        guard applyOutcome.applied else {
            return nil
        }

        sourceState.selectedNodeId = applyOutcome.newSourceFocusNodeId
        targetState.selectedNodeId = applyOutcome.targetSelectionNodeId

        return WorkspaceMoveResult(
            newFocusNodeId: applyOutcome.newSourceFocusNodeId,
            movedHandle: applyOutcome.movedHandle,
            targetWorkspaceId: targetWorkspaceId
        )
    }
}
