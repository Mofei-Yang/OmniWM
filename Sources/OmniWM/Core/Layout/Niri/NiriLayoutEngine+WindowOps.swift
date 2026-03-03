import AppKit
import Foundation

extension NiriLayoutEngine {
    func planMutation(
        op: NiriStateZigKernel.MutationOp,
        sourceWindow: NiriWindow,
        targetWindow: NiriWindow? = nil,
        direction: Direction? = nil,
        insertPosition: InsertPosition? = nil,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> (snapshot: NiriStateZigKernel.Snapshot, outcome: NiriStateZigKernel.MutationOutcome)? {
        let snapshot = NiriStateZigKernel.makeSnapshot(columns: columns(in: workspaceId))
        guard let sourceWindowIndex = snapshot.windowIndexByNodeId[sourceWindow.id] else {
            return nil
        }

        let targetWindowIndex: Int
        if let targetWindow {
            guard let resolvedTargetWindowIndex = snapshot.windowIndexByNodeId[targetWindow.id] else {
                return nil
            }
            targetWindowIndex = resolvedTargetWindowIndex
        } else {
            targetWindowIndex = -1
        }

        let request = NiriStateZigKernel.MutationRequest(
            op: op,
            sourceWindowIndex: sourceWindowIndex,
            targetWindowIndex: targetWindowIndex,
            direction: direction,
            infiniteLoop: infiniteLoop,
            insertPosition: insertPosition,
            maxWindowsPerColumn: maxWindowsPerColumn
        )

        let outcome = NiriStateZigKernel.resolveMutation(snapshot: snapshot, request: request)
        guard outcome.rc == 0 else {
            return nil
        }

        return (snapshot, outcome)
    }

    func moveWindow(
        _ node: NiriWindow,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        switch direction {
        case .down, .up:
            moveWindowVertical(node, direction: direction, in: workspaceId)
        case .left, .right:
            moveWindowHorizontal(
                node,
                direction: direction,
                in: workspaceId,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
        }
    }

    func swapWindow(
        _ node: NiriWindow,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        switch direction {
        case .down, .up:
            swapWindowVertical(node, direction: direction, in: workspaceId)
        case .left, .right:
            swapWindowHorizontal(
                node,
                direction: direction,
                in: workspaceId,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
        }
    }

    private func moveWindowVertical(
        _ node: NiriWindow,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let plan = planMutation(
            op: .moveWindowVertical,
            sourceWindow: node,
            direction: direction,
            in: workspaceId
        ) else {
            return false
        }

        let applyOutcome = NiriStateZigMutationApplier.apply(
            outcome: plan.outcome,
            snapshot: plan.snapshot,
            engine: self
        )
        return applyOutcome.applied
    }

    private func swapWindowVertical(
        _ node: NiriWindow,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let plan = planMutation(
            op: .swapWindowVertical,
            sourceWindow: node,
            direction: direction,
            in: workspaceId
        ) else {
            return false
        }

        let applyOutcome = NiriStateZigMutationApplier.apply(
            outcome: plan.outcome,
            snapshot: plan.snapshot,
            engine: self
        )
        return applyOutcome.applied
    }

    private func moveWindowHorizontal(
        _ node: NiriWindow,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        guard let plan = planMutation(
            op: .moveWindowHorizontal,
            sourceWindow: node,
            direction: direction,
            in: workspaceId
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

        let targetNode = applyOutcome.targetWindow ?? node
        ensureSelectionVisible(
            node: targetNode,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )

        return true
    }

    private func swapWindowHorizontal(
        _ node: NiriWindow,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        guard let plan = planMutation(
            op: .swapWindowHorizontal,
            sourceWindow: node,
            direction: direction,
            in: workspaceId
        ) else {
            return false
        }

        let now = animationClock?.now() ?? CACurrentMediaTime()
        let preCols = columns(in: workspaceId)
        let swapEdit = plan.outcome.edits.first(where: { $0.kind == .swapWindows })

        var sourceWindowForAnimation: NiriWindow?
        var targetWindowForAnimation: NiriWindow?
        var sourcePt: CGPoint?
        var targetPt: CGPoint?

        if let swapEdit,
           plan.snapshot.windowEntries.indices.contains(swapEdit.subjectIndex),
           plan.snapshot.windowEntries.indices.contains(swapEdit.relatedIndex)
        {
            let sourceEntry = plan.snapshot.windowEntries[swapEdit.subjectIndex]
            let targetEntry = plan.snapshot.windowEntries[swapEdit.relatedIndex]
            sourceWindowForAnimation = sourceEntry.window
            targetWindowForAnimation = targetEntry.window

            if let sourceColIdx = columnIndex(of: sourceEntry.column, in: workspaceId),
               let targetColIdx = columnIndex(of: targetEntry.column, in: workspaceId)
            {
                let sourceColX = state.columnX(at: sourceColIdx, columns: preCols, gap: gaps)
                let targetColX = state.columnX(at: targetColIdx, columns: preCols, gap: gaps)
                let sourceColRenderOffset = sourceEntry.column.renderOffset(at: now)
                let targetColRenderOffset = targetEntry.column.renderOffset(at: now)
                let sourceTileOffset = computeTileOffset(column: sourceEntry.column, tileIdx: sourceEntry.rowIndex, gaps: gaps)
                let targetTileOffset = computeTileOffset(column: targetEntry.column, tileIdx: targetEntry.rowIndex, gaps: gaps)

                sourcePt = CGPoint(
                    x: sourceColX + sourceColRenderOffset.x,
                    y: sourceTileOffset
                )
                targetPt = CGPoint(
                    x: targetColX + targetColRenderOffset.x,
                    y: targetTileOffset
                )
            }
        }

        let applyOutcome = NiriStateZigMutationApplier.apply(
            outcome: plan.outcome,
            snapshot: plan.snapshot,
            engine: self
        )
        guard applyOutcome.applied else {
            return false
        }

        if let delegated = applyOutcome.delegatedMoveColumn {
            return moveColumn(
                delegated.column,
                direction: delegated.direction,
                in: workspaceId,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
        }

        if let sourceWindowForAnimation,
           let targetWindowForAnimation,
           let sourcePt,
           let targetPt,
           let sourceColumn = column(of: sourceWindowForAnimation),
           let targetColumn = column(of: targetWindowForAnimation),
           let newSourceColIdx = columnIndex(of: sourceColumn, in: workspaceId),
           let newTargetColIdx = columnIndex(of: targetColumn, in: workspaceId)
        {
            let newCols = columns(in: workspaceId)
            let newSourceTileIdx = sourceColumn.windowNodes.firstIndex(where: { $0 === sourceWindowForAnimation }) ?? 0
            let newTargetTileIdx = targetColumn.windowNodes.firstIndex(where: { $0 === targetWindowForAnimation }) ?? 0
            let newSourceColX = state.columnX(at: newSourceColIdx, columns: newCols, gap: gaps)
            let newTargetColX = state.columnX(at: newTargetColIdx, columns: newCols, gap: gaps)
            let newSourceTileOffset = computeTileOffset(column: sourceColumn, tileIdx: newSourceTileIdx, gaps: gaps)
            let newTargetTileOffset = computeTileOffset(column: targetColumn, tileIdx: newTargetTileIdx, gaps: gaps)

            let newSourcePt = CGPoint(x: newSourceColX, y: newSourceTileOffset)
            let newTargetPt = CGPoint(x: newTargetColX, y: newTargetTileOffset)

            targetWindowForAnimation.stopMoveAnimations()
            targetWindowForAnimation.animateMoveFrom(
                displacement: CGPoint(x: targetPt.x - newSourcePt.x, y: targetPt.y - newSourcePt.y),
                clock: animationClock,
                config: windowMovementAnimationConfig,
                displayRefreshRate: displayRefreshRate
            )

            sourceWindowForAnimation.stopMoveAnimations()
            sourceWindowForAnimation.animateMoveFrom(
                displacement: CGPoint(x: sourcePt.x - newTargetPt.x, y: sourcePt.y - newTargetPt.y),
                clock: animationClock,
                config: windowMovementAnimationConfig,
                displayRefreshRate: displayRefreshRate
            )
        }

        let targetNode = applyOutcome.targetWindow ?? node
        ensureSelectionVisible(
            node: targetNode,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )

        return true
    }
}
