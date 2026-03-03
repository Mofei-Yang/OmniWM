import AppKit
import Foundation

extension NiriLayoutEngine {
    private func validatedSourceColumn(
        for window: NiriWindow,
        expectedSourceColumn: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> NiriContainer? {
        guard let actualSourceColumn = findColumn(containing: window, in: workspaceId),
              actualSourceColumn === expectedSourceColumn
        else {
            return nil
        }
        return actualSourceColumn
    }

    private func planColumnMutation(
        op: NiriStateZigKernel.MutationOp,
        sourceWindow: NiriWindow? = nil,
        sourceColumn: NiriContainer? = nil,
        targetColumn: NiriContainer? = nil,
        insertColumnIndex: Int = -1,
        direction: Direction? = nil,
        in workspaceId: WorkspaceDescriptor.ID,
        maxVisibleColumns: Int = -1
    ) -> (snapshot: NiriStateZigKernel.Snapshot, outcome: NiriStateZigKernel.MutationOutcome)? {
        let snapshot = NiriStateZigKernel.makeSnapshot(columns: columns(in: workspaceId))

        let sourceWindowIndex: Int
        if let sourceWindow {
            guard let resolvedSourceWindow = snapshot.windowIndexByNodeId[sourceWindow.id] else {
                return nil
            }
            sourceWindowIndex = resolvedSourceWindow
        } else {
            sourceWindowIndex = -1
        }

        let sourceColumnIndex: Int
        if let sourceColumn {
            guard let resolvedSourceColumn = snapshot.columnIndexByNodeId[sourceColumn.id] else {
                return nil
            }
            sourceColumnIndex = resolvedSourceColumn
        } else {
            sourceColumnIndex = -1
        }

        let targetColumnIndex: Int
        if let targetColumn {
            guard let resolvedTargetColumn = snapshot.columnIndexByNodeId[targetColumn.id] else {
                return nil
            }
            targetColumnIndex = resolvedTargetColumn
        } else {
            targetColumnIndex = -1
        }

        let request = NiriStateZigKernel.MutationRequest(
            op: op,
            sourceWindowIndex: sourceWindowIndex,
            direction: direction,
            infiniteLoop: infiniteLoop,
            maxWindowsPerColumn: maxWindowsPerColumn,
            sourceColumnIndex: sourceColumnIndex,
            targetColumnIndex: targetColumnIndex,
            insertColumnIndex: insertColumnIndex,
            maxVisibleColumns: maxVisibleColumns
        )

        let outcome = NiriStateZigKernel.resolveMutation(snapshot: snapshot, request: request)
        guard outcome.rc == 0 else {
            return nil
        }

        return (snapshot, outcome)
    }

    func moveWindowToColumn(
        _ node: NiriWindow,
        from sourceColumn: NiriContainer,
        to targetColumn: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID,
        state _: inout ViewportState
    ) {
        guard validatedSourceColumn(
            for: node,
            expectedSourceColumn: sourceColumn,
            in: workspaceId
        ) != nil else {
            return
        }

        guard let plan = planColumnMutation(
            op: .moveWindowToColumn,
            sourceWindow: node,
            targetColumn: targetColumn,
            in: workspaceId
        ) else {
            return
        }

        _ = NiriStateZigMutationApplier.apply(
            outcome: plan.outcome,
            snapshot: plan.snapshot,
            engine: self
        )
    }

    func createColumnAndMove(
        _ node: NiriWindow,
        from sourceColumn: NiriContainer,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        gaps: CGFloat,
        workingAreaWidth: CGFloat
    ) {
        guard validatedSourceColumn(
            for: node,
            expectedSourceColumn: sourceColumn,
            in: workspaceId
        ) != nil else {
            return
        }

        let insertionDirection: Direction = direction == .right ? .right : .left

        guard let plan = planColumnMutation(
            op: .createColumnAndMove,
            sourceWindow: node,
            direction: insertionDirection,
            in: workspaceId,
            maxVisibleColumns: maxVisibleColumns
        ) else {
            return
        }

        let applyOutcome = NiriStateZigMutationApplier.apply(
            outcome: plan.outcome,
            snapshot: plan.snapshot,
            engine: self
        )
        guard applyOutcome.applied else {
            return
        }

        // Strict planner-applier contract: target-producing mutations must resolve a target window.
        guard let movedWindow = applyOutcome.targetWindow else {
            return
        }
        guard let newColumn = findColumn(containing: movedWindow, in: workspaceId),
              let newColIdx = columnIndex(of: newColumn, in: workspaceId)
        else {
            return
        }

        if newColIdx == state.activeColumnIndex + 1 {
            state.activatePrevColumnOnRemoval = state.stationary()
        }

        animateColumnsForAddition(
            columnIndex: newColIdx,
            in: workspaceId,
            state: state,
            gaps: gaps,
            workingAreaWidth: workingAreaWidth
        )
    }

    func insertWindowInNewColumn(
        _ window: NiriWindow,
        insertIndex: Int,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        guard let plan = planColumnMutation(
            op: .insertWindowInNewColumn,
            sourceWindow: window,
            insertColumnIndex: insertIndex,
            in: workspaceId,
            maxVisibleColumns: maxVisibleColumns
        ) else {
            return false
        }

        let applyOutcome = NiriStateZigMutationApplier.apply(
            outcome: plan.outcome,
            snapshot: plan.snapshot,
            engine: self
        )
        guard applyOutcome.applied else {
            return false
        }

        // Strict planner-applier contract: target-producing mutations must resolve a target window.
        guard let movedWindow = applyOutcome.targetWindow else {
            return false
        }
        if let newColumn = findColumn(containing: movedWindow, in: workspaceId),
           let newColIdx = columnIndex(of: newColumn, in: workspaceId)
        {
            animateColumnsForAddition(
                columnIndex: newColIdx,
                in: workspaceId,
                state: state,
                gaps: gaps,
                workingAreaWidth: workingFrame.width
            )
        }

        ensureSelectionVisible(
            node: movedWindow,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )

        return true
    }

    func cleanupEmptyColumn(
        _ column: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID,
        state _: inout ViewportState
    ) {
        guard let plan = planColumnMutation(
            op: .cleanupEmptyColumn,
            sourceColumn: column,
            in: workspaceId
        ) else {
            return
        }

        _ = NiriStateZigMutationApplier.apply(
            outcome: plan.outcome,
            snapshot: plan.snapshot,
            engine: self
        )
    }

    func normalizeColumnSizes(in workspaceId: WorkspaceDescriptor.ID) {
        guard let plan = planColumnMutation(
            op: .normalizeColumnSizes,
            in: workspaceId
        ) else {
            return
        }

        _ = NiriStateZigMutationApplier.apply(
            outcome: plan.outcome,
            snapshot: plan.snapshot,
            engine: self
        )
    }

    func normalizeWindowSizes(in column: NiriContainer) {
        guard let workspaceId = column.findRoot()?.workspaceId else { return }
        guard let plan = planColumnMutation(
            op: .normalizeWindowSizes,
            sourceColumn: column,
            in: workspaceId
        ) else {
            return
        }

        _ = NiriStateZigMutationApplier.apply(
            outcome: plan.outcome,
            snapshot: plan.snapshot,
            engine: self
        )
    }

    func balanceSizes(
        in workspaceId: WorkspaceDescriptor.ID,
        workingAreaWidth: CGFloat,
        gaps: CGFloat
    ) {
        guard let plan = planColumnMutation(
            op: .balanceSizes,
            in: workspaceId,
            maxVisibleColumns: maxVisibleColumns
        ) else {
            return
        }

        let applyOutcome = NiriStateZigMutationApplier.apply(
            outcome: plan.outcome,
            snapshot: plan.snapshot,
            engine: self
        )
        guard applyOutcome.applied else {
            return
        }

        let cols = columns(in: workspaceId)
        guard !cols.isEmpty else { return }

        let balancedWidth = 1.0 / CGFloat(maxVisibleColumns)
        let targetPixels = (workingAreaWidth - gaps) * balancedWidth

        for column in cols {
            column.animateWidthTo(
                newWidth: targetPixels,
                clock: animationClock,
                config: windowMovementAnimationConfig,
                displayRefreshRate: displayRefreshRate
            )
        }
    }

    func moveColumn(
        _ column: NiriContainer,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        guard direction == .left || direction == .right else { return false }

        let cols = columns(in: workspaceId)
        guard let currentIdx = columnIndex(of: column, in: workspaceId) else { return false }

        let currentColX = state.columnX(at: currentIdx, columns: cols, gap: gaps)
        let nextColX = currentIdx + 1 < cols.count
            ? state.columnX(at: currentIdx + 1, columns: cols, gap: gaps)
            : currentColX + (column.cachedWidth > 0 ? column.cachedWidth : workingFrame.width / CGFloat(maxVisibleColumns)) + gaps

        guard let plan = planColumnMutation(
            op: .moveColumn,
            sourceColumn: column,
            direction: direction,
            in: workspaceId
        ) else {
            return false
        }

        guard plan.outcome.applied,
              let swapEdit = plan.outcome.edits.first(where: { $0.kind == .swapColumns })
        else {
            return false
        }

        let targetIdx = swapEdit.relatedIndex
        let applyOutcome = NiriStateZigMutationApplier.apply(
            outcome: plan.outcome,
            snapshot: plan.snapshot,
            engine: self
        )
        guard applyOutcome.applied else {
            return false
        }

        let newCols = columns(in: workspaceId)
        guard newCols.indices.contains(currentIdx), newCols.indices.contains(targetIdx) else {
            return false
        }

        let viewOffsetDelta = -state.columnX(at: currentIdx, columns: newCols, gap: gaps) + currentColX
        state.offsetViewport(by: viewOffsetDelta)

        let newColX = state.columnX(at: targetIdx, columns: newCols, gap: gaps)
        column.animateMoveFrom(
            displacement: CGPoint(x: currentColX - newColX, y: 0),
            clock: animationClock,
            config: windowMovementAnimationConfig,
            displayRefreshRate: displayRefreshRate
        )

        let othersXOffset = nextColX - currentColX
        if currentIdx < targetIdx {
            for i in currentIdx ..< targetIdx {
                let candidate = newCols[i]
                if candidate.id != column.id {
                    candidate.animateMoveFrom(
                        displacement: CGPoint(x: othersXOffset, y: 0),
                        clock: animationClock,
                        config: windowMovementAnimationConfig,
                        displayRefreshRate: displayRefreshRate
                    )
                }
            }
        } else {
            for i in (targetIdx + 1) ... currentIdx {
                let candidate = newCols[i]
                if candidate.id != column.id {
                    candidate.animateMoveFrom(
                        displacement: CGPoint(x: -othersXOffset, y: 0),
                        clock: animationClock,
                        config: windowMovementAnimationConfig,
                        displayRefreshRate: displayRefreshRate
                    )
                }
            }
        }

        ensureColumnVisible(
            column,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            animationConfig: windowMovementAnimationConfig,
            fromContainerIndex: currentIdx
        )

        return true
    }

    func consumeWindow(
        into window: NiriWindow,
        from direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        guard direction == .left || direction == .right else { return false }

        guard let currentColumn = findColumn(containing: window, in: workspaceId),
              let currentIdx = columnIndex(of: currentColumn, in: workspaceId)
        else {
            return false
        }

        guard let plan = planColumnMutation(
            op: .consumeWindow,
            sourceWindow: window,
            direction: direction,
            in: workspaceId
        ) else {
            return false
        }

        guard plan.outcome.applied,
              let moveEdit = plan.outcome.edits.first(where: { $0.kind == .moveWindowToColumnIndex }),
              plan.snapshot.windowEntries.indices.contains(moveEdit.subjectIndex)
        else {
            return false
        }

        let movingWindow = plan.snapshot.windowEntries[moveEdit.subjectIndex].window
        let movingEntry = plan.snapshot.windowEntries[moveEdit.subjectIndex]

        let now = animationClock?.now() ?? CACurrentMediaTime()
        let cols = columns(in: workspaceId)
        let sourceColX = state.columnX(at: movingEntry.columnIndex, columns: cols, gap: gaps)
        let sourceColRenderOffset = movingEntry.column.renderOffset(at: now)
        let sourceTileOffset = computeTileOffset(column: movingEntry.column, tileIdx: movingEntry.rowIndex, gaps: gaps)

        let applyOutcome = NiriStateZigMutationApplier.apply(
            outcome: plan.outcome,
            snapshot: plan.snapshot,
            engine: self
        )
        guard applyOutcome.applied else {
            return false
        }

        if let targetColumn = findColumn(containing: movingWindow, in: workspaceId) {
            let newCols = columns(in: workspaceId)
            let targetColIdx = columnIndex(of: targetColumn, in: workspaceId) ?? currentIdx
            let targetColX = state.columnX(at: targetColIdx, columns: newCols, gap: gaps)
            let targetColRenderOffset = targetColumn.renderOffset(at: now)
            let targetTileIdx = targetColumn.windowNodes.firstIndex(where: { $0 === movingWindow }) ?? 0
            let targetTileOffset = computeTileOffset(column: targetColumn, tileIdx: targetTileIdx, gaps: gaps)

            let displacement = CGPoint(
                x: sourceColX + sourceColRenderOffset.x - (targetColX + targetColRenderOffset.x),
                y: sourceTileOffset - targetTileOffset
            )

            if displacement.x != 0 || displacement.y != 0 {
                movingWindow.animateMoveFrom(
                    displacement: displacement,
                    clock: animationClock,
                    config: windowMovementAnimationConfig,
                    displayRefreshRate: displayRefreshRate
                )
            }
        }

        ensureSelectionVisible(
            node: window,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )

        return true
    }

    func expelWindow(
        _ window: NiriWindow,
        to direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        guard direction == .left || direction == .right else { return false }

        guard let currentColumn = findColumn(containing: window, in: workspaceId),
              let currentColIdx = columnIndex(of: currentColumn, in: workspaceId)
        else {
            return false
        }

        let now = animationClock?.now() ?? CACurrentMediaTime()
        let cols = columns(in: workspaceId)

        let sourceTileIdx = currentColumn.windowNodes.firstIndex(where: { $0 === window }) ?? 0
        let sourceColX = state.columnX(at: currentColIdx, columns: cols, gap: gaps)
        let sourceColRenderOffset = currentColumn.renderOffset(at: now)
        let sourceTileOffset = computeTileOffset(column: currentColumn, tileIdx: sourceTileIdx, gaps: gaps)

        guard let plan = planColumnMutation(
            op: .expelWindow,
            sourceWindow: window,
            direction: direction,
            in: workspaceId,
            maxVisibleColumns: maxVisibleColumns
        ) else {
            return false
        }

        let applyOutcome = NiriStateZigMutationApplier.apply(
            outcome: plan.outcome,
            snapshot: plan.snapshot,
            engine: self
        )
        guard applyOutcome.applied else {
            return false
        }

        // Strict planner-applier contract: target-producing mutations must resolve a target window.
        guard let movedWindow = applyOutcome.targetWindow else {
            return false
        }
        if let newColumn = findColumn(containing: movedWindow, in: workspaceId),
           let newColIdx = columnIndex(of: newColumn, in: workspaceId)
        {
            animateColumnsForAddition(
                columnIndex: newColIdx,
                in: workspaceId,
                state: state,
                gaps: gaps,
                workingAreaWidth: workingFrame.width
            )

            let newCols = columns(in: workspaceId)
            let targetColX = state.columnX(at: newColIdx, columns: newCols, gap: gaps)
            let targetColRenderOffset = newColumn.renderOffset(at: now)
            let displacement = CGPoint(
                x: sourceColX + sourceColRenderOffset.x - (targetColX + targetColRenderOffset.x),
                y: sourceTileOffset
            )

            if displacement.x != 0 || displacement.y != 0 {
                movedWindow.animateMoveFrom(
                    displacement: displacement,
                    clock: animationClock,
                    config: windowMovementAnimationConfig,
                    displayRefreshRate: displayRefreshRate
                )
            }
        }

        ensureSelectionVisible(
            node: movedWindow,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )

        return true
    }

    private func ensureColumnVisible(
        _ column: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        animationConfig: SpringConfig? = nil,
        fromContainerIndex: Int? = nil
    ) {
        if let firstWindow = column.windowNodes.first {
            ensureSelectionVisible(
                node: firstWindow,
                in: workspaceId,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps,
                alwaysCenterSingleColumn: alwaysCenterSingleColumn,
                animationConfig: animationConfig,
                fromContainerIndex: fromContainerIndex
            )
        }
    }
}
