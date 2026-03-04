import Foundation

enum NiriStateZigRuntimeProjector {
    struct ProjectionResult {
        let applied: Bool
        let failureReason: String?
    }

    static func project(
        export: NiriStateZigKernel.RuntimeStateExport,
        hints: NiriStateZigKernel.RuntimeMutationHints = .none,
        workspaceId: WorkspaceDescriptor.ID,
        engine: NiriLayoutEngine,
        additionalHandlesById: [UUID: WindowHandle] = [:]
    ) -> ProjectionResult {
        struct ResolvedColumn {
            let column: NiriContainer
            let runtime: NiriStateZigKernel.RuntimeColumnState
            let windows: [NiriWindow]
        }

        let root = engine.ensureRoot(for: workspaceId)
        let initialColumns = root.columns
        let initialWindows = root.allWindows
        let initialWindowHandleIds = Set(initialWindows.map { $0.handle.id })

        var existingColumnsById: [NodeId: NiriContainer] = [:]
        existingColumnsById.reserveCapacity(initialColumns.count)
        for column in initialColumns {
            existingColumnsById[column.id] = column
        }

        var existingWindowsById: [NodeId: NiriWindow] = [:]
        existingWindowsById.reserveCapacity(initialWindows.count)
        for window in initialWindows {
            existingWindowsById[window.id] = window
        }

        var existingWindowsByHandleId: [UUID: NiriWindow] = [:]
        existingWindowsByHandleId.reserveCapacity(initialWindows.count)
        for window in initialWindows where existingWindowsByHandleId[window.handle.id] == nil {
            existingWindowsByHandleId[window.handle.id] = window
        }

        var handleById: [UUID: WindowHandle] = [:]
        handleById.reserveCapacity(
            engine.handleToNode.count + initialWindows.count + additionalHandlesById.count
        )
        for (handleId, handle) in additionalHandlesById {
            handleById[handleId] = handle
        }
        for handle in engine.handleToNode.keys where handleById[handle.id] == nil {
            handleById[handle.id] = handle
        }
        for window in initialWindows where handleById[window.handle.id] == nil {
            handleById[window.handle.id] = window.handle
        }

        var claimedWindowSlots = Array(repeating: false, count: export.windows.count)
        var usedColumns = Set<ObjectIdentifier>()
        var usedWindows = Set<ObjectIdentifier>()
        var resolvedColumns: [ResolvedColumn] = []
        resolvedColumns.reserveCapacity(export.columns.count)

        for (columnIndex, runtimeColumn) in export.columns.enumerated() {
            let column = existingColumnsById[runtimeColumn.columnId] ?? NiriContainer(id: runtimeColumn.columnId)
            let columnObjectId = ObjectIdentifier(column)
            guard !usedColumns.contains(columnObjectId) else {
                return fail("duplicate resolved column for id \(runtimeColumn.columnId.uuid)")
            }
            usedColumns.insert(columnObjectId)

            let start = runtimeColumn.windowStart
            let end = start + runtimeColumn.windowCount
            guard start >= 0, end >= start, end <= export.windows.count else {
                return fail("invalid runtime column window range start=\(start) count=\(runtimeColumn.windowCount)")
            }

            var resolvedWindows: [NiriWindow] = []
            resolvedWindows.reserveCapacity(runtimeColumn.windowCount)
            for idx in start ..< end {
                if claimedWindowSlots[idx] {
                    return fail("overlapping runtime window range at index \(idx)")
                }
                claimedWindowSlots[idx] = true

                let runtimeWindow = export.windows[idx]
                guard runtimeWindow.columnId == runtimeColumn.columnId else {
                    return fail("runtime window \(runtimeWindow.windowId.uuid) has mismatched column id")
                }
                guard runtimeWindow.columnIndex == columnIndex else {
                    return fail("runtime window \(runtimeWindow.windowId.uuid) has mismatched column index")
                }

                let resolvedWindow: NiriWindow
                if let nodeById = existingWindowsById[runtimeWindow.windowId] {
                    resolvedWindow = nodeById
                } else if let nodeByHandle = existingWindowsByHandleId[runtimeWindow.windowId.uuid] {
                    resolvedWindow = nodeByHandle
                } else if let handle = handleById[runtimeWindow.windowId.uuid] {
                    resolvedWindow = NiriWindow(handle: handle, id: runtimeWindow.windowId)
                } else {
                    return fail("missing window handle for runtime window id \(runtimeWindow.windowId.uuid)")
                }

                let windowObjectId = ObjectIdentifier(resolvedWindow)
                guard !usedWindows.contains(windowObjectId) else {
                    return fail("duplicate resolved window object for runtime window id \(runtimeWindow.windowId.uuid)")
                }
                usedWindows.insert(windowObjectId)
                resolvedWindows.append(resolvedWindow)
            }

            resolvedColumns.append(
                ResolvedColumn(
                    column: column,
                    runtime: runtimeColumn,
                    windows: resolvedWindows
                )
            )
        }

        if claimedWindowSlots.contains(false) {
            return fail("runtime export windows are not fully covered by column ranges")
        }

        for (targetColumnIndex, resolvedColumn) in resolvedColumns.enumerated() {
            let column = resolvedColumn.column
            root.insertChild(column, at: targetColumnIndex)
            column.size = CGFloat(resolvedColumn.runtime.sizeValue)
            column.displayMode = resolvedColumn.runtime.isTabbed ? .tabbed : .normal

            for (targetWindowIndex, window) in resolvedColumn.windows.enumerated() {
                column.insertChild(window, at: targetWindowIndex)
                window.size = CGFloat(export.windows[resolvedColumn.runtime.windowStart + targetWindowIndex].sizeValue)
            }

            if resolvedColumn.windows.isEmpty {
                column.setActiveTileIdx(0)
            } else {
                column.setActiveTileIdx(resolvedColumn.runtime.activeTileIdx)
            }

            if !resolvedColumn.runtime.isTabbed {
                for window in resolvedColumn.windows {
                    window.isHiddenInTabbedMode = false
                }
            }
        }

        let activeColumnObjects = Set(resolvedColumns.map { ObjectIdentifier($0.column) })
        for staleColumn in initialColumns where !activeColumnObjects.contains(ObjectIdentifier(staleColumn)) {
            staleColumn.remove()
        }

        let activeWindowObjects = Set(resolvedColumns.flatMap { $0.windows }.map(ObjectIdentifier.init))
        for staleWindow in initialWindows where !activeWindowObjects.contains(ObjectIdentifier(staleWindow)) {
            engine.closingHandles.remove(staleWindow.handle)
            staleWindow.remove()
        }

        let activeHandleIds = Set(root.allWindows.map { $0.handle.id })
        for (handle, node) in engine.handleToNode {
            if activeHandleIds.contains(handle.id) {
                continue
            }
            if node.findRoot()?.workspaceId == workspaceId ||
                (node.findRoot() == nil && initialWindowHandleIds.contains(handle.id))
            {
                engine.handleToNode.removeValue(forKey: handle)
            }
        }
        for window in root.allWindows {
            engine.handleToNode[window.handle] = window
        }

        if hints.resetAllColumnCachedWidths {
            for column in root.columns {
                column.cachedWidth = 0
            }
        }

        for columnId in hints.refreshTabbedVisibilityColumnIds {
            if let column = root.findNode(by: columnId) as? NiriContainer {
                engine.updateTabbedColumnVisibility(column: column)
            }
        }

        return ProjectionResult(applied: true, failureReason: nil)
    }

    private static func fail(_ reason: String) -> ProjectionResult {
        return ProjectionResult(applied: false, failureReason: reason)
    }
}
