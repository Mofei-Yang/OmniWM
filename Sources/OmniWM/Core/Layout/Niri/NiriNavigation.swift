import AppKit
import CZigLayout
import Foundation

extension NiriLayoutEngine {
    private func applyNavigationResult(
        snapshot: NiriStateZigKernel.Snapshot,
        result: OmniNiriNavigationResult
    ) {
        func refreshColumn(at rawColumnIndex: Int64) {
            guard let columnIndex = Int(exactly: rawColumnIndex),
                  snapshot.columnEntries.indices.contains(columnIndex)
            else {
                return
            }
            updateTabbedColumnVisibility(column: snapshot.columnEntries[columnIndex].column)
        }

        func applyActiveUpdate(
            enabled: UInt8,
            rawColumnIndex: Int64,
            rawActiveIndex: Int64,
            refreshFlag: UInt8
        ) {
            guard enabled != 0,
                  let columnIndex = Int(exactly: rawColumnIndex),
                  let activeIndex = Int(exactly: rawActiveIndex),
                  snapshot.columnEntries.indices.contains(columnIndex)
            else {
                return
            }

            let column = snapshot.columnEntries[columnIndex].column
            column.setActiveTileIdx(activeIndex)
            if refreshFlag != 0 {
                updateTabbedColumnVisibility(column: column)
            }
        }

        applyActiveUpdate(
            enabled: result.update_source_active_tile,
            rawColumnIndex: result.source_column_index,
            rawActiveIndex: result.source_active_tile_idx,
            refreshFlag: result.refresh_tabbed_visibility_source
        )
        applyActiveUpdate(
            enabled: result.update_target_active_tile,
            rawColumnIndex: result.target_column_index,
            rawActiveIndex: result.target_active_tile_idx,
            refreshFlag: result.refresh_tabbed_visibility_target
        )

        if result.update_source_active_tile == 0,
           result.refresh_tabbed_visibility_source != 0
        {
            refreshColumn(at: result.source_column_index)
        }

        if result.update_target_active_tile == 0,
           result.refresh_tabbed_visibility_target != 0
        {
            refreshColumn(at: result.target_column_index)
        }
    }

    private func resolveNavigation(
        snapshot: NiriStateZigKernel.Snapshot,
        op: NiriStateZigKernel.NavigationOp,
        currentSelection: NiriNode,
        direction: Direction? = nil,
        orientation: Monitor.Orientation = .horizontal,
        step: Int = 0,
        targetRowIndex: Int = -1,
        targetColumnIndex: Int = -1,
        targetWindowIndex: Int = -1,
        allowMissingSelection: Bool = false
    ) -> NiriStateZigKernel.NavigationOutcome? {
        let selection = NiriStateZigKernel.makeSelectionContext(node: currentSelection, snapshot: snapshot)
        if selection == nil, !allowMissingSelection {
            return nil
        }

        let request = NiriStateZigKernel.NavigationRequest(
            op: op,
            selection: selection,
            direction: direction,
            orientation: orientation,
            infiniteLoop: infiniteLoop,
            step: step,
            targetRowIndex: targetRowIndex,
            targetColumnIndex: targetColumnIndex,
            targetWindowIndex: targetWindowIndex
        )

        let outcome = NiriStateZigKernel.resolveNavigation(snapshot: snapshot, request: request)
        guard outcome.rc == OMNI_OK else {
            return nil
        }

        applyNavigationResult(snapshot: snapshot, result: outcome.result)
        return outcome
    }

    private func targetNode(
        from outcome: NiriStateZigKernel.NavigationOutcome,
        snapshot: NiriStateZigKernel.Snapshot
    ) -> NiriNode? {
        guard let targetIndex = outcome.targetWindowIndex,
              snapshot.windowEntries.indices.contains(targetIndex)
        else {
            return nil
        }
        return snapshot.windowEntries[targetIndex].window
    }

    func moveSelectionByColumns(
        steps: Int,
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        targetRowIndex: Int? = nil
    ) -> NiriNode? {
        guard steps != 0 else { return currentSelection }

        let snapshot = NiriStateZigKernel.makeSnapshot(columns: columns(in: workspaceId))
        guard !snapshot.columnEntries.isEmpty else { return nil }

        guard let outcome = resolveNavigation(
            snapshot: snapshot,
            op: .moveByColumns,
            currentSelection: currentSelection,
            step: steps,
            targetRowIndex: targetRowIndex ?? -1
        ) else {
            return nil
        }

        return targetNode(from: outcome, snapshot: snapshot)
    }

    func moveSelectionHorizontal(
        direction: Direction,
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        targetRowIndex: Int? = nil
    ) -> NiriNode? {
        moveSelectionCrossContainer(
            direction: direction,
            currentSelection: currentSelection,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: .horizontal,
            targetSiblingIndex: targetRowIndex
        )
    }

    private func moveSelectionCrossContainer(
        direction: Direction,
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation,
        targetSiblingIndex: Int? = nil
    ) -> NiriNode? {
        guard let step = direction.primaryStep(for: orientation) else { return nil }

        guard let newSelection = moveSelectionByColumns(
            steps: step,
            currentSelection: currentSelection,
            in: workspaceId,
            targetRowIndex: targetSiblingIndex
        ) else {
            return nil
        }

        state.activatePrevColumnOnRemoval = nil

        ensureSelectionVisible(
            node: newSelection,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn,
            orientation: orientation
        )

        return newSelection
    }

    func moveSelectionVertical(
        direction: Direction,
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID? = nil
    ) -> NiriNode? {
        moveSelectionWithinContainer(
            direction: direction,
            currentSelection: currentSelection,
            orientation: .horizontal,
            workspaceId: workspaceId
        )
    }

    private func moveSelectionWithinContainer(
        direction: Direction,
        currentSelection: NiriNode,
        orientation: Monitor.Orientation,
        workspaceId: WorkspaceDescriptor.ID? = nil
    ) -> NiriNode? {
        _ = workspaceId

        guard let step = direction.secondaryStep(for: orientation) else { return nil }

        guard let container = column(of: currentSelection) else {
            return step > 0 ? currentSelection.nextSibling() : currentSelection.prevSibling()
        }

        let snapshot = NiriStateZigKernel.makeSnapshot(columns: [container])
        guard let outcome = resolveNavigation(
            snapshot: snapshot,
            op: .moveVertical,
            currentSelection: currentSelection,
            direction: direction,
            orientation: orientation
        ) else {
            return nil
        }

        return targetNode(from: outcome, snapshot: snapshot)
    }

    func ensureSelectionVisible(
        node: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        alwaysCenterSingleColumn: Bool,
        orientation: Monitor.Orientation = .horizontal,
        animationConfig: SpringConfig? = nil,
        fromContainerIndex: Int? = nil
    ) {
        let containers = columns(in: workspaceId)
        guard !containers.isEmpty else { return }

        guard let container = column(of: node),
              let targetIdx = columnIndex(of: container, in: workspaceId)
        else {
            return
        }

        let prevIdx = fromContainerIndex ?? state.activeColumnIndex

        let sizeKeyPath: KeyPath<NiriContainer, CGFloat>
        let viewportSpan: CGFloat
        switch orientation {
        case .horizontal:
            sizeKeyPath = \.cachedWidth
            viewportSpan = workingFrame.width
        case .vertical:
            sizeKeyPath = \.cachedHeight
            viewportSpan = workingFrame.height
        }

        let oldActivePos = state.containerPosition(at: state.activeColumnIndex, containers: containers, gap: gaps, sizeKeyPath: sizeKeyPath)
        let newActivePos = state.containerPosition(at: targetIdx, containers: containers, gap: gaps, sizeKeyPath: sizeKeyPath)
        state.viewOffsetPixels.offset(delta: Double(oldActivePos - newActivePos))

        state.activeColumnIndex = targetIdx
        state.activatePrevColumnOnRemoval = nil
        state.viewOffsetToRestore = nil

        state.ensureContainerVisible(
            containerIndex: targetIdx,
            containers: containers,
            gap: gaps,
            viewportSpan: viewportSpan,
            sizeKeyPath: sizeKeyPath,
            animate: true,
            centerMode: centerFocusedColumn,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn,
            animationConfig: animationConfig,
            fromContainerIndex: prevIdx
        )

        state.selectionProgress = 0.0
    }

    func focusTarget(
        direction: Direction,
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation = .horizontal
    ) -> NiriNode? {
        let snapshot = NiriStateZigKernel.makeSnapshot(columns: columns(in: workspaceId))
        guard !snapshot.columnEntries.isEmpty else { return nil }

        guard let outcome = resolveNavigation(
            snapshot: snapshot,
            op: .focusTarget,
            currentSelection: currentSelection,
            direction: direction,
            orientation: orientation
        ),
            let target = targetNode(from: outcome, snapshot: snapshot)
        else {
            return nil
        }

        ensureSelectionVisible(
            node: target,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn,
            orientation: orientation
        )

        return target
    }

    func focusDownOrLeft(
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> NiriNode? {
        let snapshot = NiriStateZigKernel.makeSnapshot(columns: columns(in: workspaceId))
        guard !snapshot.columnEntries.isEmpty else { return nil }

        guard let outcome = resolveNavigation(
            snapshot: snapshot,
            op: .focusDownOrLeft,
            currentSelection: currentSelection
        ),
            let target = targetNode(from: outcome, snapshot: snapshot)
        else {
            return nil
        }

        ensureSelectionVisible(
            node: target,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )

        return target
    }

    func focusUpOrRight(
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> NiriNode? {
        let snapshot = NiriStateZigKernel.makeSnapshot(columns: columns(in: workspaceId))
        guard !snapshot.columnEntries.isEmpty else { return nil }

        guard let outcome = resolveNavigation(
            snapshot: snapshot,
            op: .focusUpOrRight,
            currentSelection: currentSelection
        ),
            let target = targetNode(from: outcome, snapshot: snapshot)
        else {
            return nil
        }

        ensureSelectionVisible(
            node: target,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )

        return target
    }

    func focusColumnFirst(
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> NiriNode? {
        let snapshot = NiriStateZigKernel.makeSnapshot(columns: columns(in: workspaceId))
        guard !snapshot.columnEntries.isEmpty else { return nil }

        state.activatePrevColumnOnRemoval = nil

        guard let outcome = resolveNavigation(
            snapshot: snapshot,
            op: .focusColumnFirst,
            currentSelection: currentSelection,
            allowMissingSelection: true
        ),
            let target = targetNode(from: outcome, snapshot: snapshot)
        else {
            return nil
        }

        ensureSelectionVisible(
            node: target,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )

        return target
    }

    func focusColumnLast(
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> NiriNode? {
        let snapshot = NiriStateZigKernel.makeSnapshot(columns: columns(in: workspaceId))
        guard !snapshot.columnEntries.isEmpty else { return nil }

        state.activatePrevColumnOnRemoval = nil

        guard let outcome = resolveNavigation(
            snapshot: snapshot,
            op: .focusColumnLast,
            currentSelection: currentSelection,
            allowMissingSelection: true
        ),
            let target = targetNode(from: outcome, snapshot: snapshot)
        else {
            return nil
        }

        ensureSelectionVisible(
            node: target,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )

        return target
    }

    func focusColumn(
        _ columnIndex: Int,
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> NiriNode? {
        let snapshot = NiriStateZigKernel.makeSnapshot(columns: columns(in: workspaceId))
        guard snapshot.columnEntries.indices.contains(columnIndex) else { return nil }

        state.activatePrevColumnOnRemoval = nil

        guard let outcome = resolveNavigation(
            snapshot: snapshot,
            op: .focusColumnIndex,
            currentSelection: currentSelection,
            targetColumnIndex: columnIndex,
            allowMissingSelection: true
        ),
            let target = targetNode(from: outcome, snapshot: snapshot)
        else {
            return nil
        }

        ensureSelectionVisible(
            node: target,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )

        return target
    }

    func focusWindowInColumn(
        _ windowIndex: Int,
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> NiriNode? {
        let snapshot = NiriStateZigKernel.makeSnapshot(columns: columns(in: workspaceId))
        guard !snapshot.columnEntries.isEmpty else { return nil }

        guard let outcome = resolveNavigation(
            snapshot: snapshot,
            op: .focusWindowIndex,
            currentSelection: currentSelection,
            targetWindowIndex: windowIndex
        ),
            let target = targetNode(from: outcome, snapshot: snapshot)
        else {
            return nil
        }

        ensureSelectionVisible(
            node: target,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )

        return target
    }

    func focusWindowTop(
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> NiriNode? {
        let snapshot = NiriStateZigKernel.makeSnapshot(columns: columns(in: workspaceId))
        guard !snapshot.columnEntries.isEmpty else { return nil }

        guard let outcome = resolveNavigation(
            snapshot: snapshot,
            op: .focusWindowTop,
            currentSelection: currentSelection
        ),
            let target = targetNode(from: outcome, snapshot: snapshot)
        else {
            return nil
        }

        ensureSelectionVisible(
            node: target,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )

        return target
    }

    func focusWindowBottom(
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> NiriNode? {
        let snapshot = NiriStateZigKernel.makeSnapshot(columns: columns(in: workspaceId))
        guard !snapshot.columnEntries.isEmpty else { return nil }

        guard let outcome = resolveNavigation(
            snapshot: snapshot,
            op: .focusWindowBottom,
            currentSelection: currentSelection
        ),
            let target = targetNode(from: outcome, snapshot: snapshot)
        else {
            return nil
        }

        ensureSelectionVisible(
            node: target,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )

        return target
    }

    func focusPrevious(
        currentNodeId: NodeId?,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        limitToWorkspace: Bool = true
    ) -> NiriWindow? {
        let searchWorkspaceId = limitToWorkspace ? workspaceId : nil
        guard let previousWindow = findMostRecentlyFocusedWindow(
            excluding: currentNodeId,
            in: searchWorkspaceId
        ) else {
            return nil
        }

        state.activatePrevColumnOnRemoval = nil

        ensureSelectionVisible(
            node: previousWindow,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )

        return previousWindow
    }
}
