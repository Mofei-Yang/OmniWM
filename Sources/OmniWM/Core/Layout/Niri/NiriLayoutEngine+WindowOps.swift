import AppKit
import Foundation

extension NiriLayoutEngine {
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
            moveWindowVertical(node, direction: direction)
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
            swapWindowVertical(node, direction: direction)
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

    private func moveWindowVertical(_ node: NiriWindow, direction: Direction) -> Bool {
        guard let column = node.parent as? NiriContainer else {
            return false
        }

        let sibling: NiriNode?
        switch direction {
        case .up:
            sibling = node.nextSibling()
        case .down:
            sibling = node.prevSibling()
        default:
            return false
        }

        guard let targetSibling = sibling else {
            return false
        }

        let nodeIdx = column.windowNodes.firstIndex { $0 === node }
        let siblingIdx = column.windowNodes.firstIndex { $0 === targetSibling }

        node.swapWith(targetSibling)

        if column.displayMode == .tabbed, let nIdx = nodeIdx, let sIdx = siblingIdx {
            if nIdx == column.activeTileIdx {
                column.setActiveTileIdx(sIdx)
            } else if sIdx == column.activeTileIdx {
                column.setActiveTileIdx(nIdx)
            }
        }

        return true
    }

    private func swapWindowVertical(_ node: NiriWindow, direction: Direction) -> Bool {
        moveWindowVertical(node, direction: direction)
    }

    private func moveWindowHorizontal(
        _ node: NiriWindow,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        let cols = columns(in: workspaceId)
        guard !cols.isEmpty else { return false }

        guard let currentColumn = column(of: node),
              let currentColIdx = columnIndex(of: currentColumn, in: workspaceId)
        else {
            return false
        }

        let step = (direction == .right) ? 1 : -1
        guard let targetColIdx = wrapIndex(currentColIdx + step, total: cols.count) else { return false }

        let targetColumn = cols[targetColIdx]

        if targetColumn.id == currentColumn.id {
            return false
        }

        guard targetColumn.children.count < maxWindowsPerColumn else {
            return false
        }

        moveWindowToColumn(
            node,
            from: currentColumn,
            to: targetColumn,
            in: workspaceId,
            state: &state
        )

        ensureSelectionVisible(
            node: node,
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
        let cols = columns(in: workspaceId)
        guard !cols.isEmpty else { return false }

        guard let currentColumn = column(of: node),
              let currentColIdx = columnIndex(of: currentColumn, in: workspaceId)
        else {
            return false
        }

        let step = (direction == .right) ? 1 : -1
        guard let targetColIdx = wrapIndex(currentColIdx + step, total: cols.count) else { return false }

        let targetColumn = cols[targetColIdx]
        if targetColumn.id == currentColumn.id {
            return false
        }

        let sourceWindows = currentColumn.windowNodes
        let targetWindows = targetColumn.windowNodes
        guard !targetWindows.isEmpty else { return false }

        if sourceWindows.count == 1 && targetWindows.count == 1 {
            return moveColumn(
                currentColumn,
                direction: direction,
                in: workspaceId,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
        }

        let now = animationClock?.now() ?? CACurrentMediaTime()

        let sourceActiveTileIdx = currentColumn.activeTileIdx.clamped(to: 0 ... (sourceWindows.count - 1))
        let targetActiveTileIdx = targetColumn.activeTileIdx.clamped(to: 0 ... (targetWindows.count - 1))

        let sourceActiveWindow = sourceWindows[sourceActiveTileIdx]
        let targetActiveWindow = targetWindows[targetActiveTileIdx]

        let sourceColX = state.columnX(at: currentColIdx, columns: cols, gap: gaps)
        let targetColX = state.columnX(at: targetColIdx, columns: cols, gap: gaps)
        let sourceColRenderOffset = currentColumn.renderOffset(at: now)
        let targetColRenderOffset = targetColumn.renderOffset(at: now)
        let sourceTileOffset = computeTileOffset(column: currentColumn, tileIdx: sourceActiveTileIdx, gaps: gaps)
        let targetTileOffset = computeTileOffset(column: targetColumn, tileIdx: targetActiveTileIdx, gaps: gaps)

        let sourcePt = CGPoint(
            x: sourceColX + sourceColRenderOffset.x,
            y: sourceTileOffset
        )
        let targetPt = CGPoint(
            x: targetColX + targetColRenderOffset.x,
            y: targetTileOffset
        )

        let sourceWidth = currentColumn.width
        let sourceIsFullWidth = currentColumn.isFullWidth
        let sourceSavedWidth = currentColumn.savedWidth
        let targetWidth = targetColumn.width
        let targetIsFullWidth = targetColumn.isFullWidth
        let targetSavedWidth = targetColumn.savedWidth

        sourceActiveWindow.detach()
        targetActiveWindow.detach()

        let sourceInsertIdx = min(sourceActiveTileIdx, currentColumn.children.count)
        let targetInsertIdx = min(targetActiveTileIdx, targetColumn.children.count)

        currentColumn.insertChild(targetActiveWindow, at: sourceInsertIdx)
        targetColumn.insertChild(sourceActiveWindow, at: targetInsertIdx)

        currentColumn.width = targetWidth
        currentColumn.isFullWidth = targetIsFullWidth
        currentColumn.savedWidth = targetSavedWidth
        targetColumn.width = sourceWidth
        targetColumn.isFullWidth = sourceIsFullWidth
        targetColumn.savedWidth = sourceSavedWidth

        currentColumn.setActiveTileIdx(sourceActiveTileIdx)
        targetColumn.setActiveTileIdx(targetActiveTileIdx)

        let newCols = columns(in: workspaceId)
        let newSourceColIdx = columnIndex(of: currentColumn, in: workspaceId) ?? currentColIdx
        let newTargetColIdx = columnIndex(of: targetColumn, in: workspaceId) ?? targetColIdx
        let newSourceColX = state.columnX(at: newSourceColIdx, columns: newCols, gap: gaps)
        let newTargetColX = state.columnX(at: newTargetColIdx, columns: newCols, gap: gaps)
        let newSourceTileOffset = computeTileOffset(column: currentColumn, tileIdx: sourceInsertIdx, gaps: gaps)
        let newTargetTileOffset = computeTileOffset(column: targetColumn, tileIdx: targetInsertIdx, gaps: gaps)

        let newSourcePt = CGPoint(x: newSourceColX, y: newSourceTileOffset)
        let newTargetPt = CGPoint(x: newTargetColX, y: newTargetTileOffset)

        targetActiveWindow.stopMoveAnimations()
        targetActiveWindow.animateMoveFrom(
            displacement: CGPoint(x: targetPt.x - newSourcePt.x, y: targetPt.y - newSourcePt.y),
            clock: animationClock,
            config: windowMovementAnimationConfig,
            displayRefreshRate: displayRefreshRate
        )

        sourceActiveWindow.stopMoveAnimations()
        sourceActiveWindow.animateMoveFrom(
            displacement: CGPoint(x: sourcePt.x - newTargetPt.x, y: sourcePt.y - newTargetPt.y),
            clock: animationClock,
            config: windowMovementAnimationConfig,
            displayRefreshRate: displayRefreshRate
        )

        if currentColumn.isTabbed {
            updateTabbedColumnVisibility(column: currentColumn)
        }
        if targetColumn.isTabbed {
            updateTabbedColumnVisibility(column: targetColumn)
        }

        ensureSelectionVisible(
            node: sourceActiveWindow,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )

        return true
    }
}
