import Foundation

enum NiriStateZigMutationApplier {
    struct ApplyOutcome {
        let applied: Bool
        let targetWindow: NiriWindow?
        let delegatedMoveColumn: (column: NiriContainer, direction: Direction)?
    }

    private static func direction(from rawCode: Int) -> Direction? {
        switch rawCode {
        case 0:
            return .left
        case 1:
            return .right
        case 2:
            return .up
        case 3:
            return .down
        default:
            return nil
        }
    }

    private static func window(
        at index: Int,
        snapshot: NiriStateZigKernel.Snapshot
    ) -> NiriWindow? {
        guard snapshot.windowEntries.indices.contains(index) else { return nil }
        return snapshot.windowEntries[index].window
    }

    private static func column(
        at index: Int,
        snapshot: NiriStateZigKernel.Snapshot
    ) -> NiriContainer? {
        guard snapshot.columnEntries.indices.contains(index) else { return nil }
        return snapshot.columnEntries[index].column
    }

    static func apply(
        outcome: NiriStateZigKernel.MutationOutcome,
        snapshot: NiriStateZigKernel.Snapshot,
        engine: NiriLayoutEngine
    ) -> ApplyOutcome {
        guard outcome.rc == 0, outcome.applied else {
            return ApplyOutcome(applied: false, targetWindow: nil, delegatedMoveColumn: nil)
        }

        let targetWindow: NiriWindow?
        if let targetIndex = outcome.targetWindowIndex {
            targetWindow = window(at: targetIndex, snapshot: snapshot)
        } else {
            targetWindow = nil
        }

        var delegatedMoveColumn: (column: NiriContainer, direction: Direction)?

        for edit in outcome.edits {
            switch edit.kind {
            case .setActiveTile:
                guard let targetColumn = column(at: edit.subjectIndex, snapshot: snapshot) else {
                    return ApplyOutcome(applied: false, targetWindow: targetWindow, delegatedMoveColumn: nil)
                }
                targetColumn.setActiveTileIdx(edit.valueA)

            case .swapWindows:
                guard let lhs = window(at: edit.subjectIndex, snapshot: snapshot),
                      let rhs = window(at: edit.relatedIndex, snapshot: snapshot)
                else {
                    return ApplyOutcome(applied: false, targetWindow: targetWindow, delegatedMoveColumn: nil)
                }
                if lhs.parent === rhs.parent {
                    lhs.swapWith(rhs)
                } else if let lhsParent = lhs.parent as? NiriContainer,
                          let rhsParent = rhs.parent as? NiriContainer,
                          let lhsIndex = lhsParent.children.firstIndex(where: { $0 === lhs }),
                          let rhsIndex = rhsParent.children.firstIndex(where: { $0 === rhs })
                {
                    lhs.detach()
                    rhs.detach()
                    lhsParent.insertChild(rhs, at: lhsIndex)
                    rhsParent.insertChild(lhs, at: rhsIndex)
                } else {
                    return ApplyOutcome(applied: false, targetWindow: targetWindow, delegatedMoveColumn: nil)
                }

            case .moveWindowToColumnIndex:
                guard let movingWindow = window(at: edit.subjectIndex, snapshot: snapshot),
                      let targetColumn = column(at: edit.relatedIndex, snapshot: snapshot)
                else {
                    return ApplyOutcome(applied: false, targetWindow: targetWindow, delegatedMoveColumn: nil)
                }
                movingWindow.detach()
                let insertRow = max(0, edit.valueA)
                targetColumn.insertChild(movingWindow, at: insertRow)

            case .swapColumnWidthState:
                guard let lhsColumn = column(at: edit.subjectIndex, snapshot: snapshot),
                      let rhsColumn = column(at: edit.relatedIndex, snapshot: snapshot)
                else {
                    return ApplyOutcome(applied: false, targetWindow: targetWindow, delegatedMoveColumn: nil)
                }

                let lhsWidth = lhsColumn.width
                let lhsIsFullWidth = lhsColumn.isFullWidth
                let lhsSavedWidth = lhsColumn.savedWidth
                let rhsWidth = rhsColumn.width
                let rhsIsFullWidth = rhsColumn.isFullWidth
                let rhsSavedWidth = rhsColumn.savedWidth

                lhsColumn.width = rhsWidth
                lhsColumn.isFullWidth = rhsIsFullWidth
                lhsColumn.savedWidth = rhsSavedWidth

                rhsColumn.width = lhsWidth
                rhsColumn.isFullWidth = lhsIsFullWidth
                rhsColumn.savedWidth = lhsSavedWidth

            case .swapWindowSizeHeight:
                guard let lhsWindow = window(at: edit.subjectIndex, snapshot: snapshot),
                      let rhsWindow = window(at: edit.relatedIndex, snapshot: snapshot)
                else {
                    return ApplyOutcome(applied: false, targetWindow: targetWindow, delegatedMoveColumn: nil)
                }

                let lhsSize = lhsWindow.size
                let lhsHeight = lhsWindow.height
                lhsWindow.size = rhsWindow.size
                lhsWindow.height = rhsWindow.height
                rhsWindow.size = lhsSize
                rhsWindow.height = lhsHeight

            case .resetWindowSizeHeight:
                guard let targetWindow = window(at: edit.subjectIndex, snapshot: snapshot) else {
                    return ApplyOutcome(applied: false, targetWindow: targetWindow, delegatedMoveColumn: nil)
                }
                targetWindow.size = 1.0
                targetWindow.height = .default

            case .removeColumnIfEmpty:
                guard let targetColumn = column(at: edit.subjectIndex, snapshot: snapshot) else {
                    return ApplyOutcome(applied: false, targetWindow: targetWindow, delegatedMoveColumn: nil)
                }
                if targetColumn.children.isEmpty {
                    targetColumn.remove()
                }

            case .refreshTabbedVisibility:
                guard let targetColumn = column(at: edit.subjectIndex, snapshot: snapshot) else {
                    return ApplyOutcome(applied: false, targetWindow: targetWindow, delegatedMoveColumn: nil)
                }
                engine.updateTabbedColumnVisibility(column: targetColumn)

            case .delegateMoveColumn:
                guard let targetColumn = column(at: edit.subjectIndex, snapshot: snapshot),
                      let direction = direction(from: edit.valueA)
                else {
                    return ApplyOutcome(applied: false, targetWindow: targetWindow, delegatedMoveColumn: nil)
                }
                delegatedMoveColumn = (targetColumn, direction)
            }
        }

        return ApplyOutcome(
            applied: true,
            targetWindow: targetWindow,
            delegatedMoveColumn: delegatedMoveColumn
        )
    }
}
