import AppKit
import Foundation

// MARK: - Core


enum CenterFocusedColumn: String, CaseIterable, Codable, Identifiable {
    case never
    case always
    case onOverflow

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .never: "Never"
        case .always: "Always"
        case .onOverflow: "On Overflow"
        }
    }
}

enum SingleWindowAspectRatio: String, CaseIterable, Codable, Identifiable {
    case none
    case ratio16x9 = "16:9"
    case ratio4x3 = "4:3"
    case ratio21x9 = "21:9"
    case square = "1:1"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: "None (Fill)"
        case .ratio16x9: "16:9"
        case .ratio4x3: "4:3"
        case .ratio21x9: "21:9"
        case .square: "Square"
        }
    }

    var ratio: CGFloat? {
        switch self {
        case .none: nil
        case .ratio16x9: 16.0 / 9.0
        case .ratio4x3: 4.0 / 3.0
        case .ratio21x9: 21.0 / 9.0
        case .square: 1.0
        }
    }
}

struct WorkingAreaContext {
    var workingFrame: CGRect
    var viewFrame: CGRect
    var scale: CGFloat
}

struct Struts {
    var left: CGFloat = 0
    var right: CGFloat = 0
    var top: CGFloat = 0
    var bottom: CGFloat = 0

    static let zero = Struts()
}

func computeWorkingArea(
    parentArea: CGRect,
    scale: CGFloat,
    struts: Struts
) -> CGRect {
    var workingArea = parentArea

    workingArea.size.width = max(0, workingArea.size.width - struts.left - struts.right)
    workingArea.origin.x += struts.left

    workingArea.size.height = max(0, workingArea.size.height - struts.top - struts.bottom)
    workingArea.origin.y += struts.bottom

    let physicalX = ceil(workingArea.origin.x * scale) / scale
    let physicalY = ceil(workingArea.origin.y * scale) / scale

    let xDiff = min(workingArea.size.width, physicalX - workingArea.origin.x)
    let yDiff = min(workingArea.size.height, physicalY - workingArea.origin.y)

    workingArea.size.width -= xDiff
    workingArea.size.height -= yDiff
    workingArea.origin.x = physicalX
    workingArea.origin.y = physicalY

    return workingArea
}

struct NiriRenderStyle {
    var tabIndicatorWidth: CGFloat

    static let `default` = NiriRenderStyle(
        tabIndicatorWidth: 0
    )
}

enum DefaultColumnWidthUpdate<Value> {
    case unchanged
    case automatic
    case fixed(Value)

    init(optionalWidth: Value?) {
        if let optionalWidth {
            self = .fixed(optionalWidth)
        } else {
            self = .automatic
        }
    }

    func map<T>(_ transform: (Value) -> T) -> DefaultColumnWidthUpdate<T> {
        switch self {
        case .unchanged:
            .unchanged
        case .automatic:
            .automatic
        case .fixed(let value):
            .fixed(transform(value))
        }
    }
}

final class NiriLayoutEngine {
    static let defaultPresetColumnWidthValues: [CGFloat] = [1.0 / 3.0, 0.5, 2.0 / 3.0]
    static let defaultPresetColumnWidths: [PresetSize] = defaultPresetColumnWidthValues.map { .proportion($0) }
    private static let presetMatchTolerance: CGFloat = 0.001

    var monitors: [Monitor.ID: NiriMonitor] = [:]

    var roots: [WorkspaceDescriptor.ID: NiriRoot] = [:]

    var tokenToNode: [WindowToken: NiriWindow] = [:]

    var closingTokens: Set<WindowToken> = []

    var framePool: [WindowToken: CGRect] = [:]
    var hiddenPool: [WindowToken: HideSide] = [:]

    var maxWindowsPerColumn: Int
    var maxVisibleColumns: Int
    var infiniteLoop: Bool

    var centerFocusedColumn: CenterFocusedColumn = .never

    var alwaysCenterSingleColumn: Bool = true

    var singleWindowAspectRatio: SingleWindowAspectRatio = .none

    var renderStyle: NiriRenderStyle = .default

    var interactiveResize: InteractiveResize?
    var interactiveMove: InteractiveMove?

    var resizeConfiguration = ResizeConfiguration.default
    var moveConfiguration = MoveConfiguration.default

    var windowMovementAnimationConfig: SpringConfig = .snappy
    var animationClock: AnimationClock?
    var displayRefreshRate: Double = 60.0

    var presetColumnWidths: [PresetSize] = NiriLayoutEngine.defaultPresetColumnWidths
    var defaultColumnWidth: CGFloat?

    init(maxWindowsPerColumn: Int = 3, maxVisibleColumns: Int = 3, infiniteLoop: Bool = false) {
        self.maxWindowsPerColumn = max(1, min(10, maxWindowsPerColumn))
        self.maxVisibleColumns = max(1, min(5, maxVisibleColumns))
        self.infiniteLoop = infiniteLoop
        centerFocusedColumn = .onOverflow
    }

    func ensureRoot(for workspaceId: WorkspaceDescriptor.ID) -> NiriRoot {
        if let existing = roots[workspaceId] {
            return existing
        }
        let root = NiriRoot(workspaceId: workspaceId)
        roots[workspaceId] = root

        let initialColumn = NiriContainer()
        root.appendChild(initialColumn)
        return root
    }

    func claimEmptyColumnIfWorkspaceEmpty(in root: NiriRoot) -> NiriContainer? {
        guard root.allWindows.isEmpty else { return nil }

        let emptyColumns = root.columns.filter(\.children.isEmpty)
        guard let target = emptyColumns.first else { return nil }

        for column in emptyColumns.dropFirst() {
            column.remove()
        }

        return target
    }

    func removeEmptyColumnsIfWorkspaceEmpty(in root: NiriRoot) {
        guard root.allWindows.isEmpty else { return }

        let emptyColumns = root.columns.filter(\.children.isEmpty)
        for column in emptyColumns {
            column.remove()
        }
    }

    func resolvedColumnResetWidth(in workspaceId: WorkspaceDescriptor.ID) -> (proportion: CGFloat, presetWidthIdx: Int?) {
        if let defaultColumnWidth {
            return (defaultColumnWidth, matchingPresetIndex(for: defaultColumnWidth))
        }

        return (1.0 / CGFloat(effectiveMaxVisibleColumns(in: workspaceId)), nil)
    }

    func initializeNewColumnWidth(_ column: NiriContainer, in workspaceId: WorkspaceDescriptor.ID) {
        let resolvedWidth = resolvedColumnResetWidth(in: workspaceId)
        column.width = .proportion(resolvedWidth.proportion)
        column.presetWidthIdx = resolvedWidth.presetWidthIdx

        column.cachedWidth = 0
        column.isFullWidth = false
        column.savedWidth = nil
        column.hasManualSingleWindowWidthOverride = false
        column.widthAnimation = nil
        column.targetWidth = nil
    }

    private func matchingPresetIndex(for width: CGFloat) -> Int? {
        presetColumnWidths.firstIndex { preset in
            guard case let .proportion(presetWidth) = preset.kind else { return false }
            return abs(presetWidth - width) <= Self.presetMatchTolerance
        }
    }

    func root(for workspaceId: WorkspaceDescriptor.ID) -> NiriRoot? {
        roots[workspaceId]
    }

    func columns(in workspaceId: WorkspaceDescriptor.ID) -> [NiriContainer] {
        guard let root = roots[workspaceId] else { return [] }
        return root.columns
    }

    struct SingleWindowLayoutContext {
        let container: NiriContainer
        let window: NiriWindow
        let aspectRatio: CGFloat
    }

    func singleWindowLayoutContext(in workspaceId: WorkspaceDescriptor.ID) -> SingleWindowLayoutContext? {
        guard let aspectRatio = effectiveSingleWindowAspectRatio(in: workspaceId).ratio else {
            return nil
        }

        let workspaceColumns = columns(in: workspaceId)
        guard workspaceColumns.count == 1,
              let column = workspaceColumns.first,
              !column.isTabbed
        else {
            return nil
        }

        let windows = column.windowNodes
        guard windows.count == 1,
              let window = windows.first,
              window.sizingMode != .fullscreen
        else {
            return nil
        }

        return SingleWindowLayoutContext(
            container: column,
            window: window,
            aspectRatio: aspectRatio
        )
    }

    func wrapIndex(_ idx: Int, total: Int, in workspaceId: WorkspaceDescriptor.ID) -> Int? {
        guard total > 0 else { return nil }
        if effectiveInfiniteLoop(in: workspaceId) {
            let modulo = total
            return ((idx % modulo) + modulo) % modulo
        } else {
            return (idx >= 0 && idx < total) ? idx : nil
        }
    }

    func findNode(by id: NodeId) -> NiriNode? {
        for root in roots.values {
            if let found = root.findNode(by: id) {
                return found
            }
        }
        return nil
    }

    func findNode(for token: WindowToken) -> NiriWindow? {
        tokenToNode[token]
    }

    func findNode(for handle: WindowHandle) -> NiriWindow? {
        findNode(for: handle.id)
    }

    func column(of node: NiriNode) -> NiriContainer? {
        var current = node
        while let parent = current.parent {
            if parent is NiriRoot {
                return current as? NiriContainer
            }
            current = parent
        }
        return nil
    }

    func columnIndex(of column: NiriNode, in workspaceId: WorkspaceDescriptor.ID) -> Int? {
        columns(in: workspaceId).firstIndex { $0 === column }
    }

    func activateWindow(_ nodeId: NodeId) {
        guard let node = findNode(by: nodeId),
              let col = column(of: node) else { return }
        let windowNodes = col.windowNodes
        let idx = windowNodes.firstIndex(where: { $0.id == nodeId }) ?? 0
        col.setActiveTileIdx(idx)
    }

    func columnX(at index: Int, columns: [NiriContainer], gaps: CGFloat) -> CGFloat {
        var x: CGFloat = 0
        for i in 0 ..< index where i < columns.count {
            x += columns[i].cachedWidth + gaps
        }
        return x
    }

    func findColumn(containing window: NiriWindow, in workspaceId: WorkspaceDescriptor.ID) -> NiriContainer? {
        guard let col = column(of: window),
              let root = col.parent as? NiriRoot,
              roots[workspaceId]?.id == root.id else { return nil }
        return col
    }

    func updateConfiguration(
        maxWindowsPerColumn: Int? = nil,
        maxVisibleColumns: Int? = nil,
        infiniteLoop: Bool? = nil,
        centerFocusedColumn: CenterFocusedColumn? = nil,
        alwaysCenterSingleColumn: Bool? = nil,
        singleWindowAspectRatio: SingleWindowAspectRatio? = nil,
        presetColumnWidths: [PresetSize]? = nil,
        defaultColumnWidth: DefaultColumnWidthUpdate<CGFloat> = .unchanged
    ) {
        if let max = maxWindowsPerColumn {
            self.maxWindowsPerColumn = max.clamped(to: 1 ... 10)
        }
        if let max = maxVisibleColumns {
            self.maxVisibleColumns = max.clamped(to: 1 ... 5)
        }
        if let loop = infiniteLoop {
            self.infiniteLoop = loop
        }
        if let center = centerFocusedColumn {
            self.centerFocusedColumn = center
        }
        if let centerSingle = alwaysCenterSingleColumn {
            self.alwaysCenterSingleColumn = centerSingle
        }
        if let aspectRatio = singleWindowAspectRatio {
            self.singleWindowAspectRatio = aspectRatio
        }
        switch defaultColumnWidth {
        case .unchanged:
            break
        case .automatic:
            self.defaultColumnWidth = nil
        case .fixed(let width):
            self.defaultColumnWidth = width.clamped(to: 0.05 ... 1.0)
        }

        if let presets = presetColumnWidths, !presets.isEmpty {
            self.presetColumnWidths = presets
            resetAllPresetWidthIndices()
        }
    }

    private func resetAllPresetWidthIndices() {
        for root in roots.values {
            for child in root.children {
                if let column = child as? NiriContainer {
                    column.presetWidthIdx = nil
                }
            }
        }
    }
}


// MARK: - Animation


extension NiriLayoutEngine {
    struct ColumnRemovalResult {
        let fallbackSelectionId: NodeId?
        let restorePreviousViewOffset: CGFloat?
    }

    func animateColumnsForRemoval(
        columnIndex removedIdx: Int,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        gaps: CGFloat
    ) -> ColumnRemovalResult {
        let cols = columns(in: workspaceId)
        guard removedIdx >= 0, removedIdx < cols.count else {
            return ColumnRemovalResult(
                fallbackSelectionId: nil,
                restorePreviousViewOffset: nil
            )
        }

        let activeIdx = state.activeColumnIndex
        let offset = columnX(at: removedIdx + 1, columns: cols, gaps: gaps)
                   - columnX(at: removedIdx, columns: cols, gaps: gaps)
        let postRemovalCount = cols.count - 1

        if activeIdx <= removedIdx {
            for col in cols[(removedIdx + 1)...] {
                if col.hasMoveAnimationRunning {
                    col.offsetMoveAnimCurrent(offset)
                } else {
                    col.animateMoveFrom(
                        displacement: CGPoint(x: offset, y: 0),
                        clock: animationClock,
                        config: windowMovementAnimationConfig,
                        displayRefreshRate: displayRefreshRate,
                        animated: motion.animationsEnabled
                    )
                }
            }
        } else {
            for col in cols[..<removedIdx] {
                if col.hasMoveAnimationRunning {
                    col.offsetMoveAnimCurrent(-offset)
                } else {
                    col.animateMoveFrom(
                        displacement: CGPoint(x: -offset, y: 0),
                        clock: animationClock,
                        config: windowMovementAnimationConfig,
                        displayRefreshRate: displayRefreshRate,
                        animated: motion.animationsEnabled
                    )
                }
            }
        }

        let removingNode = cols[removedIdx].windowNodes.first
        let fallback = removingNode.flatMap { fallbackSelectionOnRemoval(removing: $0.id, in: workspaceId) }

        if removedIdx < activeIdx {
            state.activeColumnIndex = activeIdx - 1
            state.viewOffsetPixels.offset(delta: Double(offset))
            state.activatePrevColumnOnRemoval = nil
            return ColumnRemovalResult(
                fallbackSelectionId: fallback,
                restorePreviousViewOffset: nil
            )
        } else if removedIdx == activeIdx,
                  let prevOffset = state.activatePrevColumnOnRemoval {
            let newActiveIdx = max(0, activeIdx - 1)
            state.activeColumnIndex = newActiveIdx
            state.activatePrevColumnOnRemoval = nil
            return ColumnRemovalResult(
                fallbackSelectionId: fallback,
                restorePreviousViewOffset: prevOffset
            )
        } else if removedIdx == activeIdx {
            let newActiveIdx = min(activeIdx, max(0, postRemovalCount - 1))
            state.activeColumnIndex = newActiveIdx
            state.activatePrevColumnOnRemoval = nil
            return ColumnRemovalResult(
                fallbackSelectionId: fallback,
                restorePreviousViewOffset: nil
            )
        } else {
            state.activatePrevColumnOnRemoval = nil
            return ColumnRemovalResult(
                fallbackSelectionId: fallback,
                restorePreviousViewOffset: nil
            )
        }
    }

    func animateColumnsForAddition(
        columnIndex addedIdx: Int,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: ViewportState,
        gaps: CGFloat,
        workingAreaWidth: CGFloat
    ) {
        let cols = columns(in: workspaceId)
        guard addedIdx >= 0, addedIdx < cols.count else { return }

        let addedCol = cols[addedIdx]
        let activeIdx = state.activeColumnIndex

        if addedCol.cachedWidth <= 0 {
            addedCol.resolveAndCacheWidth(workingAreaWidth: workingAreaWidth, gaps: gaps)
        }

        let offset = addedCol.cachedWidth + gaps

        if activeIdx <= addedIdx {
            for col in cols[(addedIdx + 1)...] {
                if col.hasMoveAnimationRunning {
                    col.offsetMoveAnimCurrent(-offset)
                } else {
                    col.animateMoveFrom(
                        displacement: CGPoint(x: -offset, y: 0),
                        clock: animationClock,
                        config: windowMovementAnimationConfig,
                        displayRefreshRate: displayRefreshRate,
                        animated: motion.animationsEnabled
                    )
                }
            }
        } else {
            for col in cols[..<addedIdx] {
                if col.hasMoveAnimationRunning {
                    col.offsetMoveAnimCurrent(offset)
                } else {
                    col.animateMoveFrom(
                        displacement: CGPoint(x: offset, y: 0),
                        clock: animationClock,
                        config: windowMovementAnimationConfig,
                        displayRefreshRate: displayRefreshRate,
                        animated: motion.animationsEnabled
                    )
                }
            }
        }
    }

    func tickAllColumnAnimations(in workspaceId: WorkspaceDescriptor.ID, at time: TimeInterval) -> Bool {
        guard let root = roots[workspaceId] else { return false }
        var anyRunning = false
        for column in root.columns {
            if column.tickMoveAnimation(at: time) { anyRunning = true }
            if column.tickWidthAnimation(at: time) { anyRunning = true }
        }
        return anyRunning
    }

    func hasAnyColumnAnimationsRunning(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let root = roots[workspaceId] else { return false }
        return root.columns.contains { $0.hasMoveAnimationRunning || $0.hasWidthAnimationRunning }
    }

    func calculateCombinedLayout(
        in workspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        gaps: LayoutGaps,
        state: ViewportState,
        workingArea: WorkingAreaContext? = nil,
        animationTime: TimeInterval? = nil
    ) -> [WindowToken: CGRect] {
        calculateCombinedLayoutWithVisibility(
            in: workspaceId,
            monitor: monitor,
            gaps: gaps,
            state: state,
            workingArea: workingArea,
            animationTime: animationTime
        ).frames
    }

    func calculateCombinedLayoutWithVisibility(
        in workspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        gaps: LayoutGaps,
        state: ViewportState,
        workingArea: WorkingAreaContext? = nil,
        animationTime: TimeInterval? = nil
    ) -> LayoutResult {
        let area = workingArea ?? WorkingAreaContext(
            workingFrame: monitor.visibleFrame,
            viewFrame: monitor.frame,
            scale: 2.0
        )
        let hiddenPlacementMonitor = HiddenPlacementMonitorContext(monitor)
        let hiddenPlacementMonitors = monitors.values.map(HiddenPlacementMonitorContext.init)

        let orientation = self.monitor(for: monitor.id)?.orientation ?? monitor.autoOrientation

        return calculateLayoutWithVisibility(
            state: state,
            workspaceId: workspaceId,
            monitorFrame: monitor.visibleFrame,
            screenFrame: monitor.frame,
            gaps: gaps.asTuple,
            scale: area.scale,
            workingArea: area,
            orientation: orientation,
            animationTime: animationTime,
            hiddenPlacementMonitor: hiddenPlacementMonitor,
            hiddenPlacementMonitors: hiddenPlacementMonitors
        )
    }

    func calculateCombinedLayoutUsingPools(
        in workspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        gaps: LayoutGaps,
        state: ViewportState,
        workingArea: WorkingAreaContext? = nil,
        animationTime: TimeInterval? = nil
    ) -> (frames: [WindowToken: CGRect], hiddenHandles: [WindowToken: HideSide]) {
        framePool.removeAll(keepingCapacity: true)
        hiddenPool.removeAll(keepingCapacity: true)

        let area = workingArea ?? WorkingAreaContext(
            workingFrame: monitor.visibleFrame,
            viewFrame: monitor.frame,
            scale: 2.0
        )
        let hiddenPlacementMonitor = HiddenPlacementMonitorContext(monitor)
        let hiddenPlacementMonitors = monitors.values.map(HiddenPlacementMonitorContext.init)

        let orientation = self.monitor(for: monitor.id)?.orientation ?? monitor.autoOrientation

        calculateLayoutInto(
            frames: &framePool,
            hiddenHandles: &hiddenPool,
            state: state,
            workspaceId: workspaceId,
            monitorFrame: monitor.visibleFrame,
            screenFrame: monitor.frame,
            gaps: gaps.asTuple,
            scale: area.scale,
            workingArea: area,
            orientation: orientation,
            animationTime: animationTime,
            hiddenPlacementMonitor: hiddenPlacementMonitor,
            hiddenPlacementMonitors: hiddenPlacementMonitors
        )

        return (framePool, hiddenPool)
    }

    func captureWindowFrames(in workspaceId: WorkspaceDescriptor.ID) -> [WindowToken: CGRect] {
        guard let root = root(for: workspaceId) else { return [:] }
        var frames: [WindowToken: CGRect] = [:]
        for window in root.allWindows {
            if let frame = window.renderedFrame ?? window.frame {
                frames[window.token] = frame
            }
        }
        return frames
    }

    func targetFrameForWindow(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        state: ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> CGRect? {
        if let singleWindowContext = singleWindowLayoutContext(in: workspaceId),
           singleWindowContext.window.token == token
        {
            return resolvedSingleWindowRect(
                for: singleWindowContext,
                in: workingFrame,
                scale: 1.0,
                gaps: gaps
            )
        }

        var targetState = state
        targetState.viewOffsetPixels = .static(state.viewOffsetPixels.target())

        let orientation = monitorContaining(workspace: workspaceId)
            .flatMap { monitor(for: $0)?.orientation } ?? .horizontal

        guard let projection = projectKernelLayout(
            state: targetState,
            workspaceId: workspaceId,
            workingArea: WorkingAreaContext(
                workingFrame: workingFrame,
                viewFrame: workingFrame,
                scale: 1.0
            ),
            gaps: (horizontal: gaps, vertical: gaps),
            orientation: orientation,
            animationTime: 0,
            workspaceOffset: 0,
            includeRenderOffsets: false,
            hiddenPlacementMonitor: nil,
            hiddenPlacementMonitors: []
        ),
        let windowIndex = projection.snapshot.windows.firstIndex(where: { $0.token == token }) else {
            return nil
        }

        return projection.windowOutputs[windowIndex].renderedRect
    }

    func targetFrameForWindow(
        _ handle: WindowHandle,
        in workspaceId: WorkspaceDescriptor.ID,
        state: ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> CGRect? {
        targetFrameForWindow(handle.id, in: workspaceId, state: state, workingFrame: workingFrame, gaps: gaps)
    }

    func triggerMoveAnimations(
        in workspaceId: WorkspaceDescriptor.ID,
        oldFrames: [WindowToken: CGRect],
        newFrames: [WindowToken: CGRect],
        motion: MotionSnapshot,
        threshold: CGFloat = 1.0
    ) -> Bool {
        guard let root = root(for: workspaceId) else { return false }
        var anyAnimationStarted = false

        for window in root.allWindows {
            guard let oldFrame = oldFrames[window.token],
                  let newFrame = newFrames[window.token]
            else {
                continue
            }

            let dx = oldFrame.origin.x - newFrame.origin.x
            let dy = oldFrame.origin.y - newFrame.origin.y

            if abs(dx) > threshold || abs(dy) > threshold {
                window.animateMoveFrom(
                    displacement: CGPoint(x: dx, y: dy),
                    clock: animationClock,
                    config: windowMovementAnimationConfig,
                    displayRefreshRate: displayRefreshRate,
                    animated: motion.animationsEnabled
                )
                anyAnimationStarted = true
            }
        }

        return anyAnimationStarted
    }

    func hasAnyWindowAnimationsRunning(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let root = root(for: workspaceId) else { return false }
        return root.allWindows.contains { $0.hasMoveAnimationsRunning }
    }

    func tickAllWindowAnimations(in workspaceId: WorkspaceDescriptor.ID, at time: TimeInterval) -> Bool {
        guard let root = root(for: workspaceId) else { return false }
        var anyRunning = false
        for window in root.allWindows {
            if window.tickMoveAnimations(at: time) {
                anyRunning = true
            }
        }
        return anyRunning
    }

    func computeTileOffset(column: NiriContainer, tileIdx: Int, gaps: CGFloat) -> CGFloat {
        let windows = column.windowNodes
        guard tileIdx > 0, tileIdx < windows.count else { return 0 }

        var offset: CGFloat = 0
        for i in 0 ..< tileIdx {
            let height = windows[i].resolvedHeight ?? windows[i].frame?.height ?? 0
            offset += height
            offset += gaps
        }
        return offset
    }

    func computeTileOffsets(column: NiriContainer, gaps: CGFloat) -> [CGFloat] {
        let windows = column.windowNodes
        guard !windows.isEmpty else { return [] }

        var offsets: [CGFloat] = [0]
        var y: CGFloat = 0
        for i in 0 ..< windows.count - 1 {
            let height = windows[i].resolvedHeight ?? windows[i].frame?.height ?? 0
            y += height + gaps
            offsets.append(y)
        }
        return offsets
    }

    func tilesOrigin(column: NiriContainer) -> CGPoint {
        let xOffset = column.isTabbed ? renderStyle.tabIndicatorWidth : 0
        return CGPoint(x: xOffset, y: 0)
    }
}


// MARK: - Column Operations


extension NiriLayoutEngine {
    func createColumnAndMove(
        _ node: NiriWindow,
        from sourceColumn: NiriContainer,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        gaps: CGFloat,
        workingAreaWidth: CGFloat
    ) {
        guard let sourceIndex = columnIndex(of: sourceColumn, in: workspaceId) else { return }
        let insertIndex = direction == .right ? sourceIndex + 1 : sourceIndex
        _ = insertWindowInNewColumn(
            node,
            insertIndex: insertIndex,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: workingAreaWidth, height: 1),
            gaps: gaps
        )
    }

    func insertWindowInNewColumn(
        _ window: NiriWindow,
        insertIndex: Int,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        guard let plan = callTopologyKernel(
            operation: .insertWindowInNewColumn,
            workspaceId: workspaceId,
            state: state,
            workingFrame: workingFrame,
            gaps: gaps,
            subject: window,
            insertIndex: insertIndex,
            motion: motion
        ) else {
            return false
        }

        let animationPreparation = prepareAnimationsForTopologyPlan(
            plan,
            in: workspaceId,
            state: state,
            gaps: gaps,
            motion: motion
        )
        _ = applyTopologyPlan(plan, in: workspaceId, state: &state, motion: motion)
        finalizeAnimationsForTopologyPlan(
            plan,
            preparation: animationPreparation,
            in: workspaceId,
            state: state,
            workingFrame: workingFrame,
            gaps: gaps,
            motion: motion
        )
        return true
    }

    func cleanupEmptyColumn(
        _ column: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID,
        state _: inout ViewportState
    ) {
        guard column.children.isEmpty else { return }

        column.remove()

        if let root = roots[workspaceId], root.columns.isEmpty {
            let emptyColumn = NiriContainer()
            root.appendChild(emptyColumn)
        }
    }

    func normalizeColumnSizes(in workspaceId: WorkspaceDescriptor.ID) {
        let cols = columns(in: workspaceId)
        guard cols.count > 1 else { return }

        let totalSize = cols.reduce(CGFloat(0)) { $0 + $1.size }
        let avgSize = totalSize / CGFloat(cols.count)

        for col in cols {
            let normalized = col.size / avgSize
            col.size = max(0.5, min(2.0, normalized))
        }
    }

    func normalizeWindowSizes(in column: NiriContainer) {
        let windows = column.children.compactMap { $0 as? NiriWindow }
        guard !windows.isEmpty else { return }

        let totalSize = windows.reduce(CGFloat(0)) { $0 + $1.size }
        let avgSize = totalSize / CGFloat(windows.count)

        for window in windows {
            let normalized = window.size / avgSize
            window.size = max(0.5, min(2.0, normalized))
        }
    }

    func balanceSizes(
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        workingAreaWidth: CGFloat,
        gaps: CGFloat
    ) {
        let cols = columns(in: workspaceId)
        guard !cols.isEmpty else { return }

        let resolvedWidth = resolvedColumnResetWidth(in: workspaceId)
        let targetPixels = (workingAreaWidth - gaps) * resolvedWidth.proportion

        for column in cols {
            column.width = .proportion(resolvedWidth.proportion)
            column.isFullWidth = false
            column.savedWidth = nil
            column.presetWidthIdx = resolvedWidth.presetWidthIdx
            column.hasManualSingleWindowWidthOverride = false

            column.animateWidthTo(
                newWidth: targetPixels,
                clock: animationClock,
                config: windowMovementAnimationConfig,
                displayRefreshRate: displayRefreshRate,
                animated: motion.animationsEnabled
            )

            for window in column.windowNodes {
                window.size = 1.0
            }
        }
    }

    func moveColumn(
        _ column: NiriContainer,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        guard direction == .left || direction == .right,
              let subject = column.windowNodes.first,
              let plan = callTopologyKernel(
                  operation: .moveColumn,
                  workspaceId: workspaceId,
                  state: state,
                  workingFrame: workingFrame,
                  gaps: gaps,
                  direction: direction,
                  subject: subject,
                  motion: motion
              )
        else { return false }
        guard plan.effectKind != .none else { return false }

        let animationPreparation = prepareAnimationsForTopologyPlan(
            plan,
            in: workspaceId,
            state: state,
            gaps: gaps,
            motion: motion
        )
        _ = applyTopologyPlan(
            plan,
            in: workspaceId,
            state: &state,
            motion: motion,
            animationConfig: windowMovementAnimationConfig
        )
        finalizeAnimationsForTopologyPlan(
            plan,
            preparation: animationPreparation,
            in: workspaceId,
            state: state,
            workingFrame: workingFrame,
            gaps: gaps,
            motion: motion
        )
        return true
    }

    func expelWindow(
        _ window: NiriWindow,
        to direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        moveWindow(
            window,
            direction: direction,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )
    }
}


// MARK: - Interactive Move


extension NiriLayoutEngine {
    func interactiveMoveBegin(
        windowId: NodeId,
        windowHandle: WindowHandle,
        startLocation: CGPoint,
        isInsertMode: Bool = false,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        guard interactiveMove == nil else { return false }
        guard interactiveResize == nil else { return false }

        guard let windowNode = findNode(by: windowId) as? NiriWindow else { return false }
        guard let column = findColumn(containing: windowNode, in: workspaceId) else { return false }
        guard let colIdx = columnIndex(of: column, in: workspaceId) else { return false }

        if windowNode.isFullscreen {
            return false
        }

        interactiveMove = InteractiveMove(
            windowId: windowId,
            windowHandle: windowHandle,
            workspaceId: workspaceId,
            startMouseLocation: startLocation,
            originalColumnIndex: colIdx,
            originalFrame: windowNode.renderedFrame ?? windowNode.frame ?? .zero,
            isInsertMode: isInsertMode,
            currentHoverTarget: nil
        )

        let cols = columns(in: workspaceId)
        let settings = effectiveSettings(in: workspaceId)
        state.transitionToColumn(
            colIdx,
            columns: cols,
            gap: gaps,
            viewportWidth: workingFrame.width,
            motion: motion,
            animate: false,
            centerMode: settings.centerFocusedColumn,
            alwaysCenterSingleColumn: settings.alwaysCenterSingleColumn
        )

        return true
    }

    func interactiveMoveUpdate(
        currentLocation: CGPoint,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> MoveHoverTarget? {
        guard var move = interactiveMove else { return nil }

        let dragDistance = hypot(
            currentLocation.x - move.startMouseLocation.x,
            currentLocation.y - move.startMouseLocation.y
        )
        guard dragDistance >= moveConfiguration.dragThreshold else {
            return nil
        }

        let hoverTarget = hitTestMoveTarget(
            point: currentLocation,
            excludingWindowId: move.windowId,
            isInsertMode: move.isInsertMode,
            in: workspaceId
        )

        move.currentHoverTarget = hoverTarget
        interactiveMove = move

        return hoverTarget
    }

    func interactiveMoveEnd(
        at _: CGPoint,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        guard let move = interactiveMove else { return false }
        defer { interactiveMove = nil }

        guard let target = move.currentHoverTarget else {
            return false
        }

        switch target {
        case let .window(targetNodeId, _, position):
            switch position {
            case .swap:
                return swapWindowsByMove(
                    sourceWindowId: move.windowId,
                    targetWindowId: targetNodeId,
                    in: workspaceId,
                    motion: motion,
                    state: &state,
                    workingFrame: workingFrame,
                    gaps: gaps
                )
            case .after, .before:
                return insertWindowByMove(
                    sourceWindowId: move.windowId,
                    targetWindowId: targetNodeId,
                    position: position,
                    in: workspaceId,
                    motion: motion,
                    state: &state,
                    workingFrame: workingFrame,
                    gaps: gaps
                )
            }

        case .columnGap, .workspaceEdge:
            return false
        }
    }

    func interactiveMoveCancel() {
        interactiveMove = nil
    }

    func hitTestMoveTarget(
        point: CGPoint,
        excludingWindowId: NodeId,
        isInsertMode: Bool = false,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> MoveHoverTarget? {
        guard let root = roots[workspaceId] else { return nil }

        for column in root.columns {
            for child in column.children {
                guard let window = child as? NiriWindow,
                      window.id != excludingWindowId,
                      let frame = window.renderedFrame ?? window.frame else { continue }

                if frame.contains(point) {
                    let position: InsertPosition = if isInsertMode {
                        point.y < frame.midY ? .before : .after
                    } else {
                        .swap
                    }
                    return .window(
                        nodeId: window.id,
                        handle: window.handle,
                        insertPosition: position
                    )
                }
            }
        }

        return nil
    }

    func swapWindowsByMove(
        sourceWindowId: NodeId,
        targetWindowId: NodeId,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        fromColumnIndex: Int? = nil
    ) -> Bool {
        guard let sourceWindow = findNode(by: sourceWindowId) as? NiriWindow,
              let targetWindow = findNode(by: targetWindowId) as? NiriWindow
        else {
            return false
        }

        let sourceSize = sourceWindow.size
        let sourceHeight = sourceWindow.height
        let targetSize = targetWindow.size
        let targetHeight = targetWindow.height

        guard let plan = callTopologyKernel(
            operation: .swapWindows,
            workspaceId: workspaceId,
            state: state,
            workingFrame: workingFrame,
            gaps: gaps,
            subject: sourceWindow,
            target: targetWindow,
            fromColumnIndex: fromColumnIndex,
            motion: motion
        ), plan.effectKind != .none else {
            return false
        }

        let swapsAcrossColumns = plan.result.source_column_index != plan.result.target_column_index
        _ = applyTopologyPlan(plan, in: workspaceId, state: &state, motion: motion)

        if swapsAcrossColumns {
            sourceWindow.size = targetSize
            sourceWindow.height = targetHeight
            targetWindow.size = sourceSize
            targetWindow.height = sourceHeight
        }

        return true
    }

    func insertWindowByMove(
        sourceWindowId: NodeId,
        targetWindowId: NodeId,
        position: InsertPosition,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        if position == .swap {
            return swapWindowsByMove(
                sourceWindowId: sourceWindowId,
                targetWindowId: targetWindowId,
                in: workspaceId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
        }

        guard let sourceWindow = findNode(by: sourceWindowId) as? NiriWindow,
              let targetWindow = findNode(by: targetWindowId) as? NiriWindow
        else {
            return false
        }

        guard let plan = callTopologyKernel(
            operation: .insertWindowByMove,
            workspaceId: workspaceId,
            state: state,
            workingFrame: workingFrame,
            gaps: gaps,
            subject: sourceWindow,
            target: targetWindow,
            insertIndex: topologyInsertIndex(for: position),
            motion: motion
        ), plan.effectKind != .none else {
            return false
        }

        _ = applyTopologyPlan(plan, in: workspaceId, state: &state, motion: motion)
        sourceWindow.size = 1.0
        sourceWindow.height = .default

        return true
    }

    func insertionDropzoneFrame(
        targetWindowId: NodeId,
        position: InsertPosition,
        in workspaceId: WorkspaceDescriptor.ID,
        gaps: CGFloat
    ) -> CGRect? {
        guard let targetWindow = findNode(by: targetWindowId) as? NiriWindow,
              let targetFrame = targetWindow.renderedFrame ?? targetWindow.frame,
              let column = findColumn(containing: targetWindow, in: workspaceId)
        else {
            return nil
        }

        let windows = column.windowNodes
        let n = windows.count
        let postInsertionCount = n + 1
        let firstFrame = windows.first?.renderedFrame ?? windows.first?.frame
        let lastFrame = windows.last?.renderedFrame ?? windows.last?.frame
        guard let bottom = firstFrame?.minY, let top = lastFrame?.maxY else { return nil }

        let columnHeight = top - bottom
        let totalGaps = CGFloat(postInsertionCount - 1) * gaps
        let newHeight = max(0, (columnHeight - totalGaps) / CGFloat(postInsertionCount))
        let x = targetFrame.minX
        let width = targetFrame.width

        let y: CGFloat = switch position {
        case .before:
            max(top, targetFrame.minY - gaps - newHeight)
        case .after:
            targetFrame.maxY + gaps
        case .swap:
            targetFrame.minY
        }

        return CGRect(x: x, y: y, width: width, height: newHeight)
    }
}


// MARK: - Interactive Resize


extension NiriLayoutEngine {
    func hitTestResize(
        point: CGPoint,
        in workspaceId: WorkspaceDescriptor.ID,
        threshold: CGFloat? = nil
    ) -> ResizeHitTestResult? {
        guard let root = roots[workspaceId] else { return nil }

        let threshold = threshold ?? resizeConfiguration.edgeThreshold

        for (colIdx, column) in root.columns.enumerated() {
            for child in column.children {
                guard let window = child as? NiriWindow,
                      let frame = window.renderedFrame ?? window.frame else { continue }

                if window.isFullscreen {
                    continue
                }

                let edges = detectEdges(point: point, frame: frame, threshold: threshold)
                if !edges.isEmpty {
                    return ResizeHitTestResult(
                        windowHandle: window.handle,
                        nodeId: window.id,
                        edges: edges,
                        columnIndex: colIdx,
                        windowFrame: frame
                    )
                }
            }
        }

        return nil
    }

    func hitTestTiled(
        point: CGPoint,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> NiriWindow? {
        guard let root = roots[workspaceId] else { return nil }

        for column in root.columns {
            for child in column.children {
                guard let window = child as? NiriWindow,
                      let frame = window.renderedFrame ?? window.frame else { continue }

                if frame.contains(point) {
                    return window
                }
            }
        }

        return nil
    }

    func hitTestFocusableWindow(
        point: CGPoint,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> NiriWindow? {
        guard let root = roots[workspaceId] else { return nil }

        var firstVisibleMatch: NiriWindow?

        for column in root.columns {
            for child in column.children {
                guard let window = child as? NiriWindow,
                      !window.isHiddenInTabbedMode,
                      let frame = window.renderedFrame ?? window.frame,
                      frame.contains(point)
                else {
                    continue
                }

                if window.isFullscreen {
                    return window
                }

                if firstVisibleMatch == nil {
                    firstVisibleMatch = window
                }
            }
        }

        return firstVisibleMatch
    }

    private func detectEdges(point: CGPoint, frame: CGRect, threshold: CGFloat) -> ResizeEdge {
        var edges: ResizeEdge = []

        let expandedFrame = frame.insetBy(dx: -threshold, dy: -threshold)
        guard expandedFrame.contains(point) else {
            return []
        }

        let innerFrame = frame.insetBy(dx: threshold, dy: threshold)
        if innerFrame.contains(point) {
            return []
        }

        if point.x <= frame.minX + threshold, point.x >= frame.minX - threshold {
            edges.insert(.left)
        }
        if point.x >= frame.maxX - threshold, point.x <= frame.maxX + threshold {
            edges.insert(.right)
        }
        if point.y <= frame.minY + threshold, point.y >= frame.minY - threshold {
            edges.insert(.bottom)
        }
        if point.y >= frame.maxY - threshold, point.y <= frame.maxY + threshold {
            edges.insert(.top)
        }

        return edges
    }

    func interactiveResizeBegin(
        windowId: NodeId,
        edges: ResizeEdge,
        startLocation: CGPoint,
        in workspaceId: WorkspaceDescriptor.ID,
        viewOffset: CGFloat? = nil
    ) -> Bool {
        guard interactiveResize == nil else { return false }

        guard let windowNode = findNode(by: windowId) as? NiriWindow else { return false }
        guard let column = findColumn(containing: windowNode, in: workspaceId) else { return false }
        guard let colIdx = columnIndex(of: column, in: workspaceId) else { return false }
        if windowNode.isFullscreen {
            return false
        }

        if windowNode.constraints.isFixed {
            return false
        }

        let originalColumnWidth = edges.hasHorizontal ? column.cachedWidth : nil
        let originalWindowHeight = edges.hasVertical ? windowNode.size : nil

        interactiveResize = InteractiveResize(
            windowId: windowId,
            workspaceId: workspaceId,
            originalColumnWidth: originalColumnWidth,
            originalWindowHeight: originalWindowHeight,
            edges: edges,
            startMouseLocation: startLocation,
            columnIndex: colIdx,
            originalViewOffset: edges.contains(.left) ? viewOffset : nil
        )

        return true
    }

    func interactiveResizeUpdate(
        currentLocation: CGPoint,
        monitorFrame: CGRect,
        gaps: LayoutGaps,
        viewportState: ((inout ViewportState) -> Void) -> Void = { _ in }
    ) -> Bool {
        guard let resize = interactiveResize else { return false }

        guard let windowNode = findNode(by: resize.windowId) as? NiriWindow else {
            clearInteractiveResize()
            return false
        }

        guard let column = findColumn(containing: windowNode, in: resize.workspaceId) else {
            clearInteractiveResize()
            return false
        }

        let delta = CGPoint(
            x: currentLocation.x - resize.startMouseLocation.x,
            y: currentLocation.y - resize.startMouseLocation.y
        )

        var changed = false

        if resize.edges.hasHorizontal, let originalWidth = resize.originalColumnWidth {
            var dx = delta.x

            if resize.edges.contains(.left) {
                dx = -dx
            }

            let widthBounds = column.widthBounds()
            let minWidth = widthBounds.min
            let viewportMaxWidth = monitorFrame.width - gaps.horizontal
            let maxWidth = max(
                minWidth,
                min(viewportMaxWidth, widthBounds.max ?? viewportMaxWidth)
            )

            let newWidth = originalWidth + dx
            column.cachedWidth = newWidth.clamped(to: minWidth ... maxWidth)
            column.width = .fixed(column.cachedWidth)
            changed = true

            if resize.edges.contains(.left), let origOffset = resize.originalViewOffset {
                let widthDelta = column.cachedWidth - originalWidth
                viewportState { state in
                    state.viewOffsetPixels = .static(origOffset + widthDelta)
                }
            }
        }

        if resize.edges.hasVertical, let originalHeight = resize.originalWindowHeight {
            var dy = delta.y

            if resize.edges.contains(.bottom) {
                dy = -dy
            }

            let pixelsPerWeight = calculateVerticalPixelsPerWeightUnit(
                column: column,
                monitorFrame: monitorFrame,
                gaps: gaps
            )

            if pixelsPerWeight > 0 {
                let weightDelta = dy / pixelsPerWeight
                let newWeight = originalHeight + weightDelta
                windowNode.size = newWeight.clamped(
                    to: resizeConfiguration.minWindowWeight ... resizeConfiguration.maxWindowWeight
                )
                changed = true
            }
        }

        return changed
    }

    func clearInteractiveResize() {
        interactiveResize = nil
    }

    func interactiveResizeEnd(
        windowId: NodeId? = nil,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) {
        guard let resize = interactiveResize else { return }

        if let windowId, windowId != resize.windowId {
            return
        }

        if let windowNode = findNode(by: resize.windowId) as? NiriWindow {
            ensureSelectionVisible(
                node: windowNode,
                in: resize.workspaceId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
        }

        interactiveResize = nil
    }
}


// MARK: - Monitors


extension NiriLayoutEngine {
    func ensureMonitor(
        for monitorId: Monitor.ID,
        monitor: Monitor,
        orientation: Monitor.Orientation? = nil
    ) -> NiriMonitor {
        if let existing = monitors[monitorId] {
            if let orientation {
                existing.updateOrientation(orientation)
            }
            return existing
        }
        let niriMonitor = NiriMonitor(monitor: monitor, orientation: orientation)
        monitors[monitorId] = niriMonitor
        return niriMonitor
    }

    func monitor(for monitorId: Monitor.ID) -> NiriMonitor? {
        monitors[monitorId]
    }

    func updateMonitors(_ newMonitors: [Monitor], orientations: [Monitor.ID: Monitor.Orientation] = [:]) {
        for monitor in newMonitors {
            if let niriMonitor = monitors[monitor.id] {
                let orientation = orientations[monitor.id]
                niriMonitor.updateOutputSize(monitor: monitor, orientation: orientation)
            }
        }

        let newIds = Set(newMonitors.map(\.id))
        monitors = monitors.filter { newIds.contains($0.key) }
    }

    func cleanupRemovedMonitor(_ monitorId: Monitor.ID) {
        monitors.removeValue(forKey: monitorId)
    }

    func updateMonitorOrientations(_ orientations: [Monitor.ID: Monitor.Orientation]) {
        for (monitorId, orientation) in orientations {
            monitors[monitorId]?.updateOrientation(orientation)
        }
    }

    func updateMonitorSettings(_ settings: ResolvedNiriSettings, for monitorId: Monitor.ID) {
        monitors[monitorId]?.resolvedSettings = settings
    }

    func globalResolvedSettings() -> ResolvedNiriSettings {
        ResolvedNiriSettings(
            maxVisibleColumns: maxVisibleColumns,
            maxWindowsPerColumn: maxWindowsPerColumn,
            centerFocusedColumn: centerFocusedColumn,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn,
            singleWindowAspectRatio: singleWindowAspectRatio,
            infiniteLoop: infiniteLoop
        )
    }

    func effectiveSettings(for monitorId: Monitor.ID) -> ResolvedNiriSettings {
        monitors[monitorId]?.resolvedSettings ?? globalResolvedSettings()
    }

    func effectiveSettings(in workspaceId: WorkspaceDescriptor.ID) -> ResolvedNiriSettings {
        guard let monitorId = monitorContaining(workspace: workspaceId) else {
            return globalResolvedSettings()
        }
        return effectiveSettings(for: monitorId)
    }

    func displayScale(in workspaceId: WorkspaceDescriptor.ID) -> CGFloat {
        monitorForWorkspace(workspaceId)?.scale ?? 2.0
    }

    func effectiveMaxVisibleColumns(for monitorId: Monitor.ID) -> Int {
        effectiveSettings(for: monitorId).maxVisibleColumns
    }

    func effectiveMaxVisibleColumns(in workspaceId: WorkspaceDescriptor.ID) -> Int {
        effectiveSettings(in: workspaceId).maxVisibleColumns
    }

    func effectiveMaxWindowsPerColumn(for monitorId: Monitor.ID) -> Int {
        effectiveSettings(for: monitorId).maxWindowsPerColumn
    }

    func effectiveMaxWindowsPerColumn(in workspaceId: WorkspaceDescriptor.ID) -> Int {
        effectiveSettings(in: workspaceId).maxWindowsPerColumn
    }

    func effectiveCenterFocusedColumn(for monitorId: Monitor.ID) -> CenterFocusedColumn {
        effectiveSettings(for: monitorId).centerFocusedColumn
    }

    func effectiveCenterFocusedColumn(in workspaceId: WorkspaceDescriptor.ID) -> CenterFocusedColumn {
        effectiveSettings(in: workspaceId).centerFocusedColumn
    }

    func effectiveAlwaysCenterSingleColumn(for monitorId: Monitor.ID) -> Bool {
        effectiveSettings(for: monitorId).alwaysCenterSingleColumn
    }

    func effectiveAlwaysCenterSingleColumn(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        effectiveSettings(in: workspaceId).alwaysCenterSingleColumn
    }

    func effectiveSingleWindowAspectRatio(for monitorId: Monitor.ID) -> SingleWindowAspectRatio {
        effectiveSettings(for: monitorId).singleWindowAspectRatio
    }

    func effectiveSingleWindowAspectRatio(in workspaceId: WorkspaceDescriptor.ID) -> SingleWindowAspectRatio {
        effectiveSettings(in: workspaceId).singleWindowAspectRatio
    }

    func effectiveInfiniteLoop(for monitorId: Monitor.ID) -> Bool {
        effectiveSettings(for: monitorId).infiniteLoop
    }

    func effectiveInfiniteLoop(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        effectiveSettings(in: workspaceId).infiniteLoop
    }

    /// Reassign a single workspace without pruning unrelated workspaces
    /// that are omitted from the request.
    func moveWorkspace(
        _ workspaceId: WorkspaceDescriptor.ID,
        to monitorId: Monitor.ID,
        monitor: Monitor
    ) {
        let targetMonitor = ensureMonitor(for: monitorId, monitor: monitor)
        removeWorkspaceRootCopies(workspaceId, keepingMonitorId: targetMonitor.id)
        attachWorkspaceRootIfNeeded(workspaceId, to: targetMonitor)
    }

    /// Reconcile the authoritative full workspace-to-monitor assignment set
    /// during monitor sync and prune stale duplicate roots.
    func syncWorkspaceAssignments(
        _ assignments: [(workspaceId: WorkspaceDescriptor.ID, monitor: Monitor)]
    ) {
        var desiredOwners: [WorkspaceDescriptor.ID: Monitor.ID] = [:]
        desiredOwners.reserveCapacity(assignments.count)

        for assignment in assignments {
            _ = ensureMonitor(
                for: assignment.monitor.id,
                monitor: assignment.monitor
            )
            desiredOwners[assignment.workspaceId] = assignment.monitor.id
        }

        pruneStaleWorkspaceRootCopies(desiredOwners: desiredOwners)

        for assignment in assignments where desiredOwners[assignment.workspaceId] == assignment.monitor.id {
            let targetMonitor = monitors[assignment.monitor.id] ?? ensureMonitor(
                for: assignment.monitor.id,
                monitor: assignment.monitor
            )
            attachWorkspaceRootIfNeeded(assignment.workspaceId, to: targetMonitor)
        }
    }

    func monitorContaining(workspace workspaceId: WorkspaceDescriptor.ID) -> Monitor.ID? {
        for (monitorId, niriMonitor) in monitors {
            if niriMonitor.containsWorkspace(workspaceId) {
                return monitorId
            }
        }
        return nil
    }

    func monitorForWorkspace(_ workspaceId: WorkspaceDescriptor.ID) -> NiriMonitor? {
        for niriMonitor in monitors.values {
            if niriMonitor.containsWorkspace(workspaceId) {
                return niriMonitor
            }
        }
        return nil
    }

    private func attachWorkspaceRootIfNeeded(
        _ workspaceId: WorkspaceDescriptor.ID,
        to targetMonitor: NiriMonitor
    ) {
        let root = ensureRoot(for: workspaceId)
        if let existing = targetMonitor.workspaceRoots[workspaceId], existing === root {
            return
        }
        targetMonitor.workspaceRoots[workspaceId] = root
    }

    private func pruneStaleWorkspaceRootCopies(
        desiredOwners: [WorkspaceDescriptor.ID: Monitor.ID]
    ) {
        for niriMonitor in monitors.values {
            let staleWorkspaceIds = Array(
                niriMonitor.workspaceRoots.keys.filter { workspaceId in
                    desiredOwners[workspaceId] != niriMonitor.id
                }
            )
            for workspaceId in staleWorkspaceIds {
                niriMonitor.workspaceRoots.removeValue(forKey: workspaceId)
            }
        }
    }

    private func removeWorkspaceRootCopies(
        _ workspaceId: WorkspaceDescriptor.ID,
        keepingMonitorId: Monitor.ID? = nil
    ) {
        for niriMonitor in monitors.values where niriMonitor.id != keepingMonitorId {
            niriMonitor.workspaceRoots.removeValue(forKey: workspaceId)
        }
    }
}


// MARK: - Sizing


extension NiriLayoutEngine {
    private func cachedWidthForResizeStart(
        _ column: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> CGFloat {
        if column.cachedWidth <= 0 {
            if let singleWindowContext = singleWindowLayoutContext(in: workspaceId),
               singleWindowContext.container === column
            {
                column.cachedWidth = resolvedSingleWindowRect(
                    for: singleWindowContext,
                    in: workingFrame,
                    scale: 1.0,
                    gaps: gaps
                ).width
            } else {
                column.resolveAndCacheWidth(workingAreaWidth: workingFrame.width, gaps: gaps)
            }
        }

        return column.cachedWidth
    }

    private func ensureSelectionVisibleForPendingWidth(
        _ column: NiriContainer,
        targetWidth: CGFloat,
        previousWidth: CGFloat,
        restorePreviousWidthAfterFit: Bool,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) {
        guard let window = column.windowNodes.first else { return }

        // Expose the target width only for viewport-fit math. Animated width
        // changes restore the previous cache so the spring can continue from
        // the old span; immediate width changes keep the new target cached.
        if restorePreviousWidthAfterFit {
            column.cachedWidth = targetWidth
            defer { column.cachedWidth = previousWidth }
            ensureSelectionVisible(
                node: window,
                in: workspaceId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
        } else {
            column.cachedWidth = targetWidth
            ensureSelectionVisible(
                node: window,
                in: workspaceId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
        }
    }

    func calculateVerticalPixelsPerWeightUnit(
        column: NiriContainer,
        monitorFrame: CGRect,
        gaps: LayoutGaps
    ) -> CGFloat {
        let windows = column.children
        guard !windows.isEmpty else { return 0 }

        let totalWeight = windows.reduce(CGFloat(0)) { $0 + $1.size }
        guard totalWeight > 0 else { return 0 }

        let totalGaps = CGFloat(max(0, windows.count - 1)) * gaps.vertical
        let usableHeight = monitorFrame.height - totalGaps

        return usableHeight / totalWeight
    }

    func setWindowSizingMode(
        _ window: NiriWindow,
        motion: MotionSnapshot,
        mode: SizingMode,
        state: inout ViewportState
    ) {
        let previousMode = window.sizingMode

        if previousMode == mode {
            return
        }

        if previousMode == .fullscreen, mode == .normal {
            if let savedHeight = window.savedHeight {
                window.height = savedHeight
                window.savedHeight = nil
            }

            if let savedOffset = state.viewOffsetToRestore {
                state.restoreViewOffset(savedOffset)
            }
        }

        if previousMode == .normal, mode == .fullscreen {
            window.savedHeight = window.height
            state.saveViewOffsetForFullscreen()
            window.stopMoveAnimations()
        }

        window.sizingMode = mode
    }

    func toggleFullscreen(
        _ window: NiriWindow,
        motion: MotionSnapshot,
        state: inout ViewportState
    ) {
        let newMode: SizingMode = window.sizingMode == .fullscreen ? .normal : .fullscreen
        setWindowSizingMode(window, motion: motion, mode: newMode, state: &state)
    }

    func toggleColumnWidth(
        _ column: NiriContainer,
        forwards: Bool,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) {
        guard !presetColumnWidths.isEmpty else { return }

        let previousWidth = cachedWidthForResizeStart(
            column,
            in: workspaceId,
            workingFrame: workingFrame,
            gaps: gaps
        )

        if column.isFullWidth {
            column.isFullWidth = false
            if let saved = column.savedWidth {
                column.width = saved
                column.savedWidth = nil
            }
        }

        let presetCount = presetColumnWidths.count

        let nextIdx: Int
        if let currentIdx = column.presetWidthIdx {
            if forwards {
                nextIdx = (currentIdx + 1) % presetCount
            } else {
                nextIdx = (currentIdx - 1 + presetCount) % presetCount
            }
        } else {
            let currentValue = column.width.value
            var nearestIdx = 0
            var nearestDist = CGFloat.infinity
            for (i, preset) in presetColumnWidths.enumerated() {
                let dist = abs(preset.kind.value - currentValue)
                if dist < nearestDist {
                    nearestDist = dist
                    nearestIdx = i
                }
            }

            if forwards {
                nextIdx = (nearestIdx + 1) % presetCount
            } else {
                nextIdx = nearestIdx
            }
        }

        let newWidth = presetColumnWidths[nextIdx].asProportionalSize
        column.width = newWidth
        column.presetWidthIdx = nextIdx
        column.hasManualSingleWindowWidthOverride = true

        let workingAreaWidth = workingFrame.width
        let targetPixels: CGFloat
        switch newWidth {
        case .proportion(let p):
            targetPixels = (workingAreaWidth - gaps) * p
        case .fixed(let f):
            targetPixels = f
        }

        let didStartWidthAnimation = column.animateWidthTo(
            newWidth: targetPixels,
            clock: animationClock,
            config: windowMovementAnimationConfig,
            displayRefreshRate: displayRefreshRate,
            animated: motion.animationsEnabled
        )

        ensureSelectionVisibleForPendingWidth(
            column,
            targetWidth: targetPixels,
            previousWidth: previousWidth,
            restorePreviousWidthAfterFit: didStartWidthAnimation,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )
    }

    func toggleFullWidth(
        _ column: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) {
        let workingAreaWidth = workingFrame.width
        let previousWidth = cachedWidthForResizeStart(
            column,
            in: workspaceId,
            workingFrame: workingFrame,
            gaps: gaps
        )
        let targetPixels: CGFloat
        if column.isFullWidth {
            column.isFullWidth = false
            if let saved = column.savedWidth {
                column.width = saved
                column.savedWidth = nil
            }
            column.hasManualSingleWindowWidthOverride = true
            switch column.width {
            case .proportion(let p):
                targetPixels = (workingAreaWidth - gaps) * p
            case .fixed(let f):
                targetPixels = f
            }
        } else {
            column.savedWidth = column.width
            column.isFullWidth = true
            column.presetWidthIdx = nil
            column.hasManualSingleWindowWidthOverride = true
            targetPixels = workingAreaWidth
        }

        let didStartWidthAnimation = column.animateWidthTo(
            newWidth: targetPixels,
            clock: animationClock,
            config: windowMovementAnimationConfig,
            displayRefreshRate: displayRefreshRate,
            animated: motion.animationsEnabled
        )

        ensureSelectionVisibleForPendingWidth(
            column,
            targetWidth: targetPixels,
            previousWidth: previousWidth,
            restorePreviousWidthAfterFit: didStartWidthAnimation,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )
    }

    func setWindowHeight(_ window: NiriWindow, height: WeightedSize) {
        window.height = height
    }
}


// MARK: - Tabbed Mode


extension NiriLayoutEngine {
    @discardableResult
    func toggleColumnTabbed(
        in workspaceId: WorkspaceDescriptor.ID,
        state: ViewportState,
        motion: MotionSnapshot
    ) -> Bool {
        guard let selectedId = state.selectedNodeId,
              let selectedNode = findNode(by: selectedId),
              let column = column(of: selectedNode)
        else {
            return false
        }

        let newMode: ColumnDisplay = column.displayMode == .normal ? .tabbed : .normal
        return setColumnDisplay(newMode, for: column, motion: motion)
    }

    @discardableResult
    func setColumnDisplay(
        _ mode: ColumnDisplay,
        for column: NiriContainer,
        motion: MotionSnapshot,
        gaps: CGFloat = 0
    ) -> Bool {
        guard column.displayMode != mode else { return false }

        if let resize = interactiveResize,
           let resizeWindow = findNode(by: resize.windowId) as? NiriWindow,
           let resizeColumn = findColumn(containing: resizeWindow, in: resize.workspaceId),
           resizeColumn.id == column.id
        {
            clearInteractiveResize()
        }

        let windows = column.windowNodes
        guard !windows.isEmpty else {
            column.displayMode = mode
            return true
        }

        let prevOrigin = tilesOrigin(column: column)

        column.displayMode = mode
        let newOrigin = tilesOrigin(column: column)
        let originDelta = CGPoint(x: prevOrigin.x - newOrigin.x, y: prevOrigin.y - newOrigin.y)

        column.displayMode = .normal
        let tileOffsets = computeTileOffsets(column: column, gaps: gaps)

        for (idx, window) in windows.enumerated() {
            var yDelta = idx < tileOffsets.count ? tileOffsets[idx] : 0
            yDelta -= prevOrigin.y

            if mode == .normal {
                yDelta *= -1
            }

            let delta = CGPoint(x: originDelta.x, y: originDelta.y + yDelta)
            if delta.x != 0 || delta.y != 0 {
                window.animateMoveFrom(
                    displacement: delta,
                    clock: animationClock,
                    config: windowMovementAnimationConfig,
                    displayRefreshRate: displayRefreshRate,
                    animated: motion.animationsEnabled
                )
            }
        }

        column.displayMode = mode
        updateTabbedColumnVisibility(column: column)

        return true
    }

    func updateTabbedColumnVisibility(column: NiriContainer) {
        let windows = column.windowNodes
        guard !windows.isEmpty else { return }

        column.clampActiveTileIdx()

        if column.displayMode == .tabbed {
            for (idx, window) in windows.enumerated() {
                let isActive = idx == column.activeTileIdx
                window.isHiddenInTabbedMode = !isActive
            }
        } else {
            for window in windows {
                window.isHiddenInTabbedMode = false
            }
        }
    }

    @discardableResult
    func activateTab(at index: Int, in column: NiriContainer) -> Bool {
        guard column.displayMode == .tabbed else { return false }

        let prevIdx = column.activeTileIdx
        column.setActiveTileIdx(index)

        if prevIdx != column.activeTileIdx {
            updateTabbedColumnVisibility(column: column)
            return true
        }
        return false
    }

    func activeColumn(in _: WorkspaceDescriptor.ID, state: ViewportState) -> NiriContainer? {
        guard let selectedId = state.selectedNodeId,
              let selectedNode = findNode(by: selectedId)
        else {
            return nil
        }
        return column(of: selectedNode)
    }
}


// MARK: - Window Operations


extension NiriLayoutEngine {
    func moveWindow(
        _ node: NiriWindow,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        let oldColumnIndex = findColumn(containing: node, in: workspaceId)
            .flatMap { columnIndex(of: $0, in: workspaceId) }
        let oldColumnPosition = oldColumnIndex.map { state.columnX(at: $0, columns: columns(in: workspaceId), gap: gaps) }
        let oldTileIndex = (node.parent as? NiriContainer)?.windowNodes.firstIndex { $0 === node } ?? 0
        let oldTileOffset = (node.parent as? NiriContainer).map {
            computeTileOffset(column: $0, tileIdx: oldTileIndex, gaps: gaps)
        } ?? 0

        guard let plan = callTopologyKernel(
            operation: .moveWindow,
            workspaceId: workspaceId,
            state: state,
            workingFrame: workingFrame,
            gaps: gaps,
            direction: direction,
            subject: node,
            motion: motion
        ) else {
            return false
        }

        let effect = plan.effectKind
        guard effect != .none else {
            return false
        }

        let animationPreparation = prepareAnimationsForTopologyPlan(
            plan,
            in: workspaceId,
            state: state,
            gaps: gaps,
            motion: motion
        )
        let targetColumnIndex = Int(plan.result.target_column_index)
        let targetWindowIndex = Int(plan.result.target_window_index)
        _ = applyTopologyPlan(
            plan,
            in: workspaceId,
            state: &state,
            motion: motion,
            animationConfig: windowMovementAnimationConfig
        )
        finalizeAnimationsForTopologyPlan(
            plan,
            preparation: animationPreparation,
            in: workspaceId,
            state: state,
            workingFrame: workingFrame,
            gaps: gaps,
            motion: motion
        )

        if direction == .left || direction == .right,
           let oldColumnPosition,
           targetColumnIndex >= 0,
           let movedWindow = findNode(for: node.token),
           let targetColumn = findColumn(containing: movedWindow, in: workspaceId)
        {
            let newColumns = columns(in: workspaceId)
            let targetColumnPosition = state.columnX(at: targetColumnIndex, columns: newColumns, gap: gaps)
            let targetTileOffset = computeTileOffset(
                column: targetColumn,
                tileIdx: max(0, targetWindowIndex),
                gaps: gaps
            )
            let columnDisplacement: CGFloat = if effect == .consumeWindow, direction == .right {
                targetColumn.cachedWidth + gaps
            } else {
                0
            }
            let displacement = CGPoint(
                x: oldColumnPosition - targetColumnPosition - columnDisplacement,
                y: oldTileOffset - targetTileOffset
            )
            if displacement.x != 0 || displacement.y != 0 {
                movedWindow.animateMoveFrom(
                    displacement: displacement,
                    clock: animationClock,
                    config: windowMovementAnimationConfig,
                    displayRefreshRate: displayRefreshRate,
                    animated: motion.animationsEnabled
                )
            }
        }

        return true
    }
}


// MARK: - Window Queries


extension NiriLayoutEngine {
    func updateWindowConstraints(for token: WindowToken, constraints: WindowSizeConstraints) {
        guard let node = tokenToNode[token] else { return }
        node.constraints = constraints.normalized()
    }

    func addWindow(
        token: WindowToken,
        to workspaceId: WorkspaceDescriptor.ID,
        afterSelection selectedNodeId: NodeId?,
        focusedToken: WindowToken? = nil
    ) -> NiriWindow {
        var state = ViewportState()
        state.selectedNodeId = selectedNodeId

        guard let plan = callTopologyKernel(
            operation: .addWindow,
            workspaceId: workspaceId,
            state: state,
            workingFrame: CGRect(x: 0, y: 0, width: 1, height: 1),
            gaps: 0,
            subjectToken: token,
            focusedToken: focusedToken,
            motion: .disabled
        ) else { preconditionFailure("Niri topology kernel failed to add window") }

        applyTopologyPlan(plan, in: workspaceId)
        return findNode(for: token)!
    }

    func removeWindow(token: WindowToken) {
        guard let node = tokenToNode[token] else { return }
        let state = ViewportState()
        guard let root = node.findRoot(),
              let plan = callTopologyKernel(
                  operation: .removeWindow,
                  workspaceId: root.workspaceId,
                  state: state,
                  workingFrame: CGRect(x: 0, y: 0, width: 1, height: 1),
                  gaps: 0,
                  subject: node,
                  motion: .disabled
              )
        else { return }

        applyTopologyPlan(plan, in: root.workspaceId)
    }

    @discardableResult
    func rekeyWindow(from oldToken: WindowToken, to newToken: WindowToken) -> Bool {
        guard oldToken != newToken,
              tokenToNode[newToken] == nil,
              let node = tokenToNode.removeValue(forKey: oldToken)
        else {
            return false
        }

        node.token = newToken
        tokenToNode[newToken] = node

        if let frame = framePool.removeValue(forKey: oldToken) {
            framePool[newToken] = frame
        }
        if let hiddenSide = hiddenPool.removeValue(forKey: oldToken) {
            hiddenPool[newToken] = hiddenSide
        }
        if closingTokens.remove(oldToken) != nil {
            closingTokens.insert(newToken)
        }

        node.invalidateChildrenCache()
        return true
    }

    @discardableResult
    func syncWindows(
        _ tokens: [WindowToken],
        in workspaceId: WorkspaceDescriptor.ID,
        selectedNodeId: NodeId?,
        focusedToken: WindowToken? = nil
    ) -> Set<WindowToken> {
        let root = ensureRoot(for: workspaceId)
        let existingIdSet = root.windowIdSet
        var state = ViewportState()
        state.selectedNodeId = selectedNodeId

        if let plan = callTopologyKernel(
            operation: .syncWindows,
            workspaceId: workspaceId,
            state: state,
            workingFrame: CGRect(x: 0, y: 0, width: 1, height: 1),
            gaps: 0,
            focusedToken: focusedToken,
            desiredTokens: tokens,
            motion: .disabled,
            hasCompletedInitialRefresh: false
        ) {
            applyTopologyPlan(plan, in: workspaceId)
        }

        return existingIdSet.subtracting(Set(tokens))
    }

    func validateSelection(
        _ selectedNodeId: NodeId?,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> NodeId? {
        guard let selectedId = selectedNodeId else {
            return columns(in: workspaceId).first?.firstChild()?.id
        }

        guard let root = roots[workspaceId],
              let existingNode = root.findNode(by: selectedId)
        else {
            return columns(in: workspaceId).first?.firstChild()?.id
        }

        return existingNode.id
    }

    func fallbackSelectionOnRemoval(
        removing removingNodeId: NodeId,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> NodeId? {
        topologyFallbackSelectionOnRemoval(removing: removingNodeId, in: workspaceId)
    }

    func updateFocusTimestamp(for nodeId: NodeId) {
        guard let node = findNode(by: nodeId) as? NiriWindow else { return }
        node.lastFocusedTime = Date()
    }

    func updateFocusTimestamp(for token: WindowToken) {
        guard let node = findNode(for: token) else { return }
        node.lastFocusedTime = Date()
    }

    func findMostRecentlyFocusedWindow(
        excluding excludingNodeId: NodeId?,
        in workspaceId: WorkspaceDescriptor.ID? = nil
    ) -> NiriWindow? {
        let allWindows: [NiriWindow] = if let wsId = workspaceId, let root = root(for: wsId) {
            root.allWindows
        } else {
            Array(roots.values.flatMap(\.allWindows))
        }

        let candidates = allWindows.filter { window in
            window.id != excludingNodeId && window.lastFocusedTime != nil
        }

        return candidates.max { ($0.lastFocusedTime ?? .distantPast) < ($1.lastFocusedTime ?? .distantPast) }
    }

}


// MARK: - Workspace Operations


extension NiriLayoutEngine {
    struct WorkspaceMoveResult {
        let newFocusNodeId: NodeId?

        let movedHandle: WindowHandle?

        let targetWorkspaceId: WorkspaceDescriptor.ID
    }

    func moveWindowToWorkspace(
        _ window: NiriWindow,
        from sourceWorkspaceId: WorkspaceDescriptor.ID,
        to targetWorkspaceId: WorkspaceDescriptor.ID,
        sourceState: inout ViewportState,
        targetState: inout ViewportState
    ) -> WorkspaceMoveResult? {
        guard sourceWorkspaceId != targetWorkspaceId else { return nil }

        guard roots[sourceWorkspaceId] != nil,
              let sourceColumn = findColumn(containing: window, in: sourceWorkspaceId)
        else {
            return nil
        }

        let targetRoot = ensureRoot(for: targetWorkspaceId)

        let fallbackSelection = fallbackSelectionOnRemoval(removing: window.id, in: sourceWorkspaceId)

        window.detach()

        let targetColumn: NiriContainer
        if let existingColumn = claimEmptyColumnIfWorkspaceEmpty(in: targetRoot) {
            initializeNewColumnWidth(existingColumn, in: targetWorkspaceId)
            targetColumn = existingColumn
        } else {
            let newColumn = NiriContainer()
            initializeNewColumnWidth(newColumn, in: targetWorkspaceId)
            targetRoot.appendChild(newColumn)
            targetColumn = newColumn
        }
        targetColumn.appendChild(window)

        cleanupEmptyColumn(sourceColumn, in: sourceWorkspaceId, state: &sourceState)

        sourceState.selectedNodeId = fallbackSelection

        targetState.selectedNodeId = window.id

        return WorkspaceMoveResult(
            newFocusNodeId: fallbackSelection,
            movedHandle: window.handle,
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
        guard sourceWorkspaceId != targetWorkspaceId else { return nil }

        guard let sourceRoot = roots[sourceWorkspaceId],
              columnIndex(of: column, in: sourceWorkspaceId) != nil
        else {
            return nil
        }

        let targetRoot = ensureRoot(for: targetWorkspaceId)

        removeEmptyColumnsIfWorkspaceEmpty(in: targetRoot)

        let allCols = columns(in: sourceWorkspaceId)
        var fallbackSelection: NodeId?
        if let colIdx = columnIndex(of: column, in: sourceWorkspaceId) {
            if colIdx > 0 {
                fallbackSelection = allCols[colIdx - 1].firstChild()?.id
            } else if allCols.count > 1 {
                fallbackSelection = allCols[1].firstChild()?.id
            }
        }

        column.detach()

        targetRoot.appendChild(column)

        if sourceRoot.columns.isEmpty {
            let emptyColumn = NiriContainer()
            sourceRoot.appendChild(emptyColumn)
        }

        sourceState.selectedNodeId = fallbackSelection

        targetState.selectedNodeId = column.firstChild()?.id

        let firstWindowHandle = column.windowNodes.first?.handle

        return WorkspaceMoveResult(
            newFocusNodeId: fallbackSelection,
            movedHandle: firstWindowHandle,
            targetWorkspaceId: targetWorkspaceId
        )
    }

    func adjacentWorkspace(
        from workspaceId: WorkspaceDescriptor.ID,
        direction: Direction,
        workspaceIds: [WorkspaceDescriptor.ID]
    ) -> WorkspaceDescriptor.ID? {
        guard direction == .up || direction == .down else { return nil }

        guard let currentIdx = workspaceIds.firstIndex(of: workspaceId) else { return nil }

        let targetIdx: Int = if direction == .up {
            currentIdx - 1
        } else {
            currentIdx + 1
        }

        guard workspaceIds.indices.contains(targetIdx) else { return nil }
        return workspaceIds[targetIdx]
    }
}
