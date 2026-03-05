import Foundation

extension NiriLayoutEngine {
    func setRuntimeMirrorState(
        for workspaceId: WorkspaceDescriptor.ID,
        columnCount: Int,
        windowCount: Int
    ) {
        runtimeMirrorStates[workspaceId] = RuntimeMirrorState(
            isSeeded: true,
            columnCount: columnCount,
            windowCount: windowCount
        )
    }

    func prepareSeededRuntimeContext(
        for workspaceId: WorkspaceDescriptor.ID,
        snapshot: NiriStateZigKernel.Snapshot
    ) -> NiriLayoutZigKernel.LayoutContext? {
        guard let context = ensureLayoutContext(for: workspaceId) else {
            return nil
        }
        let seedRC = NiriStateZigKernel.seedRuntimeState(
            context: context,
            snapshot: snapshot
        )
        guard seedRC == 0 else {
            return nil
        }

        setRuntimeMirrorState(
            for: workspaceId,
            columnCount: snapshot.columns.count,
            windowCount: snapshot.windows.count
        )
        return context
    }

    func applyProjectedRuntimeExport(
        context: NiriLayoutZigKernel.LayoutContext,
        workspaceId: WorkspaceDescriptor.ID,
        hints: NiriStateZigKernel.RuntimeMutationHints = .none,
        refreshMirrorStateFromExport: Bool = true
    ) -> NiriStateZigKernel.RuntimeStateExport? {
        let exported = NiriStateZigKernel.exportRuntimeState(context: context)
        guard exported.rc == 0 else {
            return nil
        }

        let projection = NiriStateZigRuntimeProjector.project(
            export: exported.export,
            hints: hints,
            workspaceId: workspaceId,
            engine: self
        )
        guard projection.applied else {
            return nil
        }

        if refreshMirrorStateFromExport {
            setRuntimeMirrorState(
                for: workspaceId,
                columnCount: exported.export.columns.count,
                windowCount: exported.export.windows.count
            )
        }

        return exported.export
    }

    func navigationRefreshColumnIds(
        sourceColumnId: NodeId?,
        targetColumnId: NodeId?
    ) -> [NodeId] {
        var refreshColumnIds: [NodeId] = []
        if let sourceColumnId {
            refreshColumnIds.append(sourceColumnId)
        }
        if let targetColumnId, !refreshColumnIds.contains(targetColumnId) {
            refreshColumnIds.append(targetColumnId)
        }
        return refreshColumnIds
    }

    func navigationRuntimeHints(
        sourceColumnId: NodeId?,
        targetColumnId: NodeId?
    ) -> NiriStateZigKernel.RuntimeMutationHints {
        NiriStateZigKernel.RuntimeMutationHints(
            refreshTabbedVisibilityColumnIds: navigationRefreshColumnIds(
                sourceColumnId: sourceColumnId,
                targetColumnId: targetColumnId
            ),
            resetAllColumnCachedWidths: false,
            delegatedMoveColumn: nil
        )
    }
}
