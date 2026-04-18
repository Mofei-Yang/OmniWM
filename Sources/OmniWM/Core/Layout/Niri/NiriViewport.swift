import AppKit
import COmniWMKernels
import Foundation

// MARK: - State


final class ViewGesture {
    let tracker: SwipeTracker
    let isTrackpad: Bool

    var currentViewOffset: Double
    var animation: SpringAnimation?
    var stationaryViewOffset: Double
    var deltaFromTracker: Double

    init(currentViewOffset: Double, isTrackpad: Bool) {
        self.tracker = SwipeTracker()
        self.currentViewOffset = currentViewOffset
        self.stationaryViewOffset = currentViewOffset
        self.deltaFromTracker = currentViewOffset
        self.isTrackpad = isTrackpad
    }

    func applyDelta(_ delta: Double) {
        currentViewOffset += delta
        stationaryViewOffset += delta
        deltaFromTracker += delta
    }

    func current() -> Double {
        if let anim = animation {
            return currentViewOffset + (anim.value(at: CACurrentMediaTime()) - anim.from)
        }
        return currentViewOffset
    }

    func value(at time: TimeInterval) -> Double {
        if let anim = animation {
            return currentViewOffset + (anim.value(at: time) - anim.from)
        }
        return currentViewOffset
    }

    func currentVelocity() -> Double {
        if let anim = animation {
            return anim.velocity(at: CACurrentMediaTime())
        }
        return tracker.velocity()
    }

    func velocity(at time: TimeInterval) -> Double {
        if let anim = animation {
            return anim.velocity(at: time)
        }
        return tracker.velocity()
    }
}

enum ViewOffset {
    case `static`(CGFloat)
    case gesture(ViewGesture)
    case spring(SpringAnimation)

    func current() -> CGFloat {
        switch self {
        case let .static(offset):
            offset
        case let .gesture(g):
            CGFloat(g.current())
        case let .spring(anim):
            CGFloat(anim.value(at: CACurrentMediaTime()))
        }
    }

    func value(at time: TimeInterval) -> CGFloat {
        switch self {
        case let .static(offset):
            offset
        case let .gesture(g):
            CGFloat(g.value(at: time))
        case let .spring(anim):
            CGFloat(anim.value(at: time))
        }
    }

    func target() -> CGFloat {
        switch self {
        case let .static(offset):
            offset
        case let .gesture(g):
            CGFloat(g.currentViewOffset)
        case let .spring(anim):
            CGFloat(anim.target)
        }
    }

    var isAnimating: Bool {
        switch self {
        case .spring:
            return true
        case let .gesture(g):
            return g.animation != nil
        case .static:
            return false
        }
    }

    var isGesture: Bool {
        if case .gesture = self { return true }
        return false
    }

    var gestureRef: ViewGesture? {
        if case let .gesture(g) = self { return g }
        return nil
    }

    mutating func offset(delta: Double) {
        switch self {
        case .static(let offset):
            self = .static(CGFloat(Double(offset) + delta))
        case .spring(let anim):
            anim.offsetBy(delta)
        case .gesture(let g):
            g.applyDelta(delta)
        }
    }

    func currentVelocity(at time: TimeInterval = CACurrentMediaTime()) -> Double {
        switch self {
        case .static:
            0
        case let .gesture(g):
            g.currentVelocity()
        case let .spring(anim):
            anim.velocity(at: time)
        }
    }

    func velocity(at time: TimeInterval) -> Double {
        switch self {
        case .static:
            0
        case let .gesture(g):
            g.velocity(at: time)
        case let .spring(anim):
            anim.velocity(at: time)
        }
    }
}

struct ViewportState {
    var activeColumnIndex: Int = 0

    var viewOffsetPixels: ViewOffset = .static(0.0)

    var selectionProgress: CGFloat = 0.0

    var selectedNodeId: NodeId?

    var viewOffsetToRestore: CGFloat?

    var activatePrevColumnOnRemoval: CGFloat?

    let springConfig: SpringConfig = .snappy

    var animationClock: AnimationClock?

    var displayRefreshRate: Double = 60.0
}


// MARK: - Animation


extension ViewportState {
    func viewPosPixels(columns: [NiriContainer], gap: CGFloat) -> CGFloat {
        let activeColX = columnX(at: activeColumnIndex, columns: columns, gap: gap)
        return activeColX + viewOffsetPixels.current()
    }

    func targetViewPosPixels(columns: [NiriContainer], gap: CGFloat) -> CGFloat {
        let activeColX = columnX(at: activeColumnIndex, columns: columns, gap: gap)
        return activeColX + viewOffsetPixels.target()
    }

    func currentViewOffset() -> CGFloat {
        viewOffsetPixels.current()
    }

    func stationary() -> CGFloat {
        switch viewOffsetPixels {
        case .static(let offset):
            return offset
        case .spring(let anim):
            return CGFloat(anim.target)
        case .gesture(let g):
            return CGFloat(g.stationaryViewOffset)
        }
    }

    mutating func advanceAnimations(at time: CFTimeInterval) -> Bool {
        return tickAnimation(at: time)
    }

    mutating func tickAnimation(at time: CFTimeInterval = CACurrentMediaTime()) -> Bool {
        switch viewOffsetPixels {
        case let .spring(anim):
            if anim.isComplete(at: time) {
                let finalOffset = CGFloat(anim.target)
                viewOffsetPixels = .static(finalOffset)
                return false
            }
            return true

        case let .gesture(gesture):
            if let anim = gesture.animation {
                if anim.isComplete(at: time) {
                    gesture.animation = nil
                    return false
                }
                return true
            }
            return false

        default:
            return false
        }
    }

    mutating func animateToOffset(
        _ offset: CGFloat,
        motion: MotionSnapshot,
        config: SpringConfig? = nil,
        scale: CGFloat = 2.0
    ) {
        guard motion.animationsEnabled else {
            viewOffsetPixels = .static(offset)
            return
        }

        let now = animationClock?.now() ?? CACurrentMediaTime()
        let pixel: CGFloat = 1.0 / scale

        let toDiff = offset - viewOffsetPixels.target()
        if abs(toDiff) < pixel {
            viewOffsetPixels.offset(delta: Double(toDiff))
            return
        }

        let currentOffset = viewOffsetPixels.current()
        let velocity = viewOffsetPixels.currentVelocity()

        let animation = SpringAnimation(
            from: Double(currentOffset),
            to: Double(offset),
            initialVelocity: velocity,
            startTime: now,
            config: config ?? springConfig,
            displayRefreshRate: displayRefreshRate
        )
        viewOffsetPixels = .spring(animation)
    }

    mutating func cancelAnimation() {
        viewOffsetPixels = .static(viewOffsetPixels.target())
    }

    mutating func reset() {
        activeColumnIndex = 0
        viewOffsetPixels = .static(0.0)
        selectionProgress = 0.0
        selectedNodeId = nil
    }

    mutating func offsetViewport(by delta: CGFloat) {
        let current = viewOffsetPixels.current()
        viewOffsetPixels = .static(current + delta)
    }

    mutating func saveViewOffsetForFullscreen() {
        viewOffsetToRestore = stationary()
    }

    mutating func restoreViewOffset(_ offset: CGFloat) {
        guard !viewOffsetPixels.isGesture else {
            viewOffsetToRestore = nil
            return
        }

        viewOffsetPixels = .static(offset)
        viewOffsetToRestore = nil
    }

    mutating func clearSavedViewOffset() {
        viewOffsetToRestore = nil
    }
}


// MARK: - Column Transitions


extension ViewportState {
    mutating func setActiveColumn(
        _ index: Int,
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat,
        motion: MotionSnapshot,
        animate: Bool = false
    ) {
        guard !columns.isEmpty else { return }
        let clampedIndex = index.clamped(to: 0 ... (columns.count - 1))

        let oldActiveColX = columnX(at: activeColumnIndex, columns: columns, gap: gap)
        let newActiveColX = columnX(at: clampedIndex, columns: columns, gap: gap)
        let offsetDelta = oldActiveColX - newActiveColX

        viewOffsetPixels.offset(delta: Double(offsetDelta))

        let targetOffset = computeCenteredOffset(
            columnIndex: clampedIndex,
            columns: columns,
            gap: gap,
            viewportWidth: viewportWidth
        )

        if animate {
            animateToOffset(targetOffset, motion: motion)
        } else {
            viewOffsetPixels = .static(targetOffset)
        }

        activeColumnIndex = clampedIndex
        activatePrevColumnOnRemoval = nil
        viewOffsetToRestore = nil
    }

    mutating func transitionToColumn(
        _ newIndex: Int,
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat,
        motion: MotionSnapshot,
        animate: Bool,
        centerMode: CenterFocusedColumn,
        alwaysCenterSingleColumn: Bool = false,
        fromColumnIndex: Int? = nil,
        scale: CGFloat = 2.0
    ) {
        guard !columns.isEmpty else { return }
        let clampedIndex = newIndex.clamped(to: 0 ... (columns.count - 1))

        let oldActiveColX = columnX(at: activeColumnIndex, columns: columns, gap: gap)

        let prevActiveColumn = activeColumnIndex
        activeColumnIndex = clampedIndex

        let newActiveColX = columnX(at: clampedIndex, columns: columns, gap: gap)
        let offsetDelta = oldActiveColX - newActiveColX

        viewOffsetPixels.offset(delta: Double(offsetDelta))

        let targetOffset = computeVisibleOffset(
            columnIndex: clampedIndex,
            columns: columns,
            gap: gap,
            viewportWidth: viewportWidth,
            currentOffset: viewOffsetPixels.target(),
            centerMode: centerMode,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn,
            fromColumnIndex: fromColumnIndex ?? prevActiveColumn,
            scale: scale
        )

        let pixel: CGFloat = 1.0 / max(scale, 1.0)
        let toDiff = targetOffset - viewOffsetPixels.target()
        if abs(toDiff) < pixel {
            viewOffsetPixels.offset(delta: Double(toDiff))
            activatePrevColumnOnRemoval = nil
            viewOffsetToRestore = nil
            return
        }

        if animate {
            animateToOffset(targetOffset, motion: motion)
        } else {
            viewOffsetPixels = .static(targetOffset)
        }

        activatePrevColumnOnRemoval = nil
        viewOffsetToRestore = nil
    }

    mutating func ensureContainerVisible(
        containerIndex: Int,
        containers: [NiriContainer],
        gap: CGFloat,
        viewportSpan: CGFloat,
        motion: MotionSnapshot,
        sizeKeyPath: KeyPath<NiriContainer, CGFloat>,
        animate: Bool = true,
        centerMode: CenterFocusedColumn = .never,
        alwaysCenterSingleColumn: Bool = false,
        animationConfig: SpringConfig? = nil,
        fromContainerIndex: Int? = nil,
        scale: CGFloat = 2.0
    ) {
        guard !containers.isEmpty, containerIndex >= 0, containerIndex < containers.count else { return }

        let stationaryOffset = stationary()
        let activePos = containerPosition(at: activeColumnIndex, containers: containers, gap: gap, sizeKeyPath: sizeKeyPath)
        let stationaryViewStart = activePos + stationaryOffset
        let pixelEpsilon: CGFloat = 1.0 / max(scale, 1.0)

        let targetOffset = computeVisibleOffset(
            containerIndex: containerIndex,
            containers: containers,
            gap: gap,
            viewportSpan: viewportSpan,
            sizeKeyPath: sizeKeyPath,
            currentViewStart: stationaryViewStart,
            centerMode: centerMode,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn,
            fromContainerIndex: fromContainerIndex,
            scale: scale
        )

        if abs(targetOffset - stationaryOffset) <= pixelEpsilon {
            return
        }

        if animate {
            animateToOffset(
                targetOffset,
                motion: motion,
                config: animationConfig,
                scale: scale
            )
        } else {
            viewOffsetPixels = .static(targetOffset)
        }
    }

    mutating func snapToColumn(
        _ columnIndex: Int,
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat
    ) {
        guard !columns.isEmpty else { return }
        let clampedIndex = columnIndex.clamped(to: 0 ... (columns.count - 1))
        activeColumnIndex = clampedIndex

        let targetOffset = computeCenteredOffset(
            columnIndex: clampedIndex,
            columns: columns,
            gap: gap,
            viewportWidth: viewportWidth
        )
        viewOffsetPixels = .static(targetOffset)
        selectionProgress = 0
    }

    mutating func scrollByPixels(
        _ deltaPixels: CGFloat,
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat,
        changeSelection: Bool
    ) -> Int? {
        guard abs(deltaPixels) > CGFloat.ulpOfOne else { return nil }
        guard !columns.isEmpty else { return nil }

        let totalW = totalWidth(columns: columns, gap: gap)
        guard totalW > 0 else { return nil }

        let currentOffset = viewOffsetPixels.current()
        let newOffset = currentOffset + deltaPixels

        viewOffsetPixels = .static(newOffset)

        if changeSelection {
            selectionProgress += deltaPixels
            let avgColumnWidth = totalW / CGFloat(columns.count)
            let steps = Int((selectionProgress / avgColumnWidth).rounded(.towardZero))
            if steps != 0 {
                selectionProgress -= CGFloat(steps) * avgColumnWidth
                return steps
            }
        }

        return nil
    }
}


// MARK: - Geometry


private extension CenterFocusedColumn {
    var zigRawValue: UInt32 {
        switch self {
        case .never:
            return UInt32(OMNIWM_CENTER_FOCUSED_COLUMN_NEVER)
        case .always:
            return UInt32(OMNIWM_CENTER_FOCUSED_COLUMN_ALWAYS)
        case .onOverflow:
            return UInt32(OMNIWM_CENTER_FOCUSED_COLUMN_ON_OVERFLOW)
        }
    }
}

private extension SizingMode {
    var viewportGeometryRawValue: UInt8 {
        switch self {
        case .normal:
            return UInt8(OMNIWM_NIRI_WINDOW_SIZING_NORMAL)
        case .fullscreen:
            return UInt8(OMNIWM_NIRI_WINDOW_SIZING_FULLSCREEN)
        }
    }
}

extension ViewportState {
    struct GeometrySnapTarget {
        let viewPos: Double
        let columnIndex: Int
    }

    private func withViewportBuffers<Result>(
        containers: [NiriContainer],
        sizeKeyPath: KeyPath<NiriContainer, CGFloat>,
        _ body: (UnsafeBufferPointer<Double>, UnsafeBufferPointer<UInt8>) -> Result
    ) -> Result {
        withUnsafeTemporaryAllocation(of: Double.self, capacity: containers.count) { spans in
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: containers.count) { modes in
                for (index, container) in containers.enumerated() {
                    spans[index] = container[keyPath: sizeKeyPath]
                    modes[index] = container.effectiveSizingMode.viewportGeometryRawValue
                }
                return body(
                    UnsafeBufferPointer(start: spans.baseAddress, count: containers.count),
                    UnsafeBufferPointer(start: modes.baseAddress, count: containers.count)
                )
            }
        }
    }

    func columnX(at index: Int, columns: [NiriContainer], gap: CGFloat) -> CGFloat {
        containerPosition(at: index, containers: columns, gap: gap, sizeKeyPath: \.cachedWidth)
    }

    func totalWidth(columns: [NiriContainer], gap: CGFloat) -> CGFloat {
        totalSpan(containers: columns, gap: gap, sizeKeyPath: \.cachedWidth)
    }

    func containerPosition(
        at index: Int,
        containers: [NiriContainer],
        gap: CGFloat,
        sizeKeyPath: KeyPath<NiriContainer, CGFloat>
    ) -> CGFloat {
        guard index >= 0 else { return 0 }

        return withViewportBuffers(containers: containers, sizeKeyPath: sizeKeyPath) { spans, _ in
            omniwm_geometry_container_position(
                spans.baseAddress,
                spans.count,
                gap,
                numericCast(index)
            )
        }
    }

    func totalSpan(
        containers: [NiriContainer],
        gap: CGFloat,
        sizeKeyPath: KeyPath<NiriContainer, CGFloat>
    ) -> CGFloat {
        withViewportBuffers(containers: containers, sizeKeyPath: sizeKeyPath) { spans, _ in
            omniwm_geometry_total_span(
                spans.baseAddress,
                spans.count,
                gap
            )
        }
    }

    func computeCenteredOffset(
        containerIndex: Int,
        containers: [NiriContainer],
        gap: CGFloat,
        viewportSpan: CGFloat,
        sizeKeyPath: KeyPath<NiriContainer, CGFloat>
    ) -> CGFloat {
        guard containerIndex >= 0 else { return 0 }

        return withViewportBuffers(containers: containers, sizeKeyPath: sizeKeyPath) { spans, modes in
            omniwm_geometry_centered_offset(
                spans.baseAddress,
                modes.baseAddress,
                spans.count,
                gap,
                viewportSpan,
                numericCast(containerIndex)
            )
        }
    }

    func computeVisibleOffset(
        containerIndex: Int,
        containers: [NiriContainer],
        gap: CGFloat,
        viewportSpan: CGFloat,
        sizeKeyPath: KeyPath<NiriContainer, CGFloat>,
        currentViewStart: CGFloat,
        centerMode: CenterFocusedColumn,
        alwaysCenterSingleColumn: Bool = false,
        fromContainerIndex: Int? = nil,
        scale: CGFloat = 2.0
    ) -> CGFloat {
        guard containerIndex >= 0 else { return 0 }

        return withViewportBuffers(containers: containers, sizeKeyPath: sizeKeyPath) { spans, modes in
            omniwm_geometry_visible_offset(
                spans.baseAddress,
                modes.baseAddress,
                spans.count,
                gap,
                viewportSpan,
                Int32(containerIndex),
                currentViewStart,
                centerMode.zigRawValue,
                alwaysCenterSingleColumn ? 1 : 0,
                Int32(fromContainerIndex ?? -1),
                scale
            )
        }
    }

    func snapTarget(
        projectedViewPos: Double,
        currentViewPos: Double,
        containers: [NiriContainer],
        gap: CGFloat,
        viewportSpan: CGFloat,
        sizeKeyPath: KeyPath<NiriContainer, CGFloat>,
        centerMode: CenterFocusedColumn,
        alwaysCenterSingleColumn: Bool = false
    ) -> GeometrySnapTarget {
        guard !containers.isEmpty else {
            return GeometrySnapTarget(viewPos: 0, columnIndex: 0)
        }

        return withViewportBuffers(containers: containers, sizeKeyPath: sizeKeyPath) { spans, modes in
            let result = omniwm_geometry_snap_target(
                spans.baseAddress,
                modes.baseAddress,
                spans.count,
                gap,
                viewportSpan,
                projectedViewPos,
                currentViewPos,
                centerMode.zigRawValue,
                alwaysCenterSingleColumn ? 1 : 0
            )
            return GeometrySnapTarget(
                viewPos: result.view_pos,
                columnIndex: numericCast(result.column_index)
            )
        }
    }

    func computeCenteredOffset(
        columnIndex: Int,
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat
    ) -> CGFloat {
        computeCenteredOffset(
            containerIndex: columnIndex,
            containers: columns,
            gap: gap,
            viewportSpan: viewportWidth,
            sizeKeyPath: \.cachedWidth
        )
    }

    func computeVisibleOffset(
        columnIndex: Int,
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat,
        currentOffset: CGFloat,
        centerMode: CenterFocusedColumn,
        alwaysCenterSingleColumn: Bool = false,
        fromColumnIndex: Int? = nil,
        scale: CGFloat = 2.0
    ) -> CGFloat {
        let columnPosition = columnX(at: columnIndex, columns: columns, gap: gap)
        return computeVisibleOffset(
            containerIndex: columnIndex,
            containers: columns,
            gap: gap,
            viewportSpan: viewportWidth,
            sizeKeyPath: \.cachedWidth,
            currentViewStart: columnPosition + currentOffset,
            centerMode: centerMode,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn,
            fromContainerIndex: fromColumnIndex,
            scale: scale
        )
    }

    func snapTarget(
        projectedViewPos: Double,
        currentViewPos: Double,
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat,
        centerMode: CenterFocusedColumn,
        alwaysCenterSingleColumn: Bool = false
    ) -> GeometrySnapTarget {
        snapTarget(
            projectedViewPos: projectedViewPos,
            currentViewPos: currentViewPos,
            containers: columns,
            gap: gap,
            viewportSpan: viewportWidth,
            sizeKeyPath: \.cachedWidth,
            centerMode: centerMode,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )
    }
}


// MARK: - Gestures


private let viewGestureWorkingAreaMovement: Double = 1200.0

extension ViewportState {
    mutating func beginGesture(isTrackpad: Bool) {
        let currentOffset = viewOffsetPixels.current()
        viewOffsetPixels = .gesture(ViewGesture(currentViewOffset: Double(currentOffset), isTrackpad: isTrackpad))
        selectionProgress = 0.0
    }

    mutating func updateGesture(
        deltaPixels: CGFloat,
        timestamp: TimeInterval,
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat
    ) -> Int? {
        guard case let .gesture(gesture) = viewOffsetPixels else {
            return nil
        }

        gesture.tracker.push(delta: Double(deltaPixels), timestamp: timestamp)

        let normFactor = gesture.isTrackpad
            ? Double(viewportWidth) / viewGestureWorkingAreaMovement
            : 1.0
        let pos = gesture.tracker.position * normFactor
        let viewOffset = pos + gesture.deltaFromTracker

        guard !columns.isEmpty else {
            gesture.currentViewOffset = viewOffset
            return nil
        }

        gesture.currentViewOffset = viewOffset

        let totalColumnWidth = Double(totalWidth(columns: columns, gap: gap))
        guard totalColumnWidth.isFinite, totalColumnWidth > 0 else {
            return nil
        }

        let avgColumnWidth = totalColumnWidth / Double(columns.count)
        guard avgColumnWidth.isFinite, avgColumnWidth > 0 else {
            return nil
        }

        selectionProgress += deltaPixels
        let steps = Int((selectionProgress / CGFloat(avgColumnWidth)).rounded(.towardZero))
        if steps != 0 {
            selectionProgress -= CGFloat(steps) * CGFloat(avgColumnWidth)
            return steps
        }
        return nil
    }

    mutating func endGesture(
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat,
        motion: MotionSnapshot,
        centerMode: CenterFocusedColumn = .never,
        alwaysCenterSingleColumn: Bool = false
    ) {
        guard case let .gesture(gesture) = viewOffsetPixels else {
            return
        }

        let currentOffset = gesture.current()

        guard !columns.isEmpty else {
            endGestureWithoutSnap(currentOffset: currentOffset)
            return
        }

        let totalColumnWidth = Double(totalWidth(columns: columns, gap: gap))
        guard totalColumnWidth.isFinite, totalColumnWidth > 0 else {
            endGestureWithoutSnap(currentOffset: currentOffset)
            return
        }

        let velocity = gesture.currentVelocity()
        let normFactor = gesture.isTrackpad
            ? Double(viewportWidth) / viewGestureWorkingAreaMovement
            : 1.0
        let projectedTrackerPos = gesture.tracker.projectedEndPosition() * normFactor
        let projectedOffset = projectedTrackerPos + gesture.deltaFromTracker

        let activeColX = columnX(at: activeColumnIndex, columns: columns, gap: gap)
        let currentViewPos = Double(activeColX) + currentOffset
        let projectedViewPos = Double(activeColX) + projectedOffset

        let result = snapTarget(
            projectedViewPos: projectedViewPos,
            currentViewPos: currentViewPos,
            columns: columns,
            gap: gap,
            viewportWidth: viewportWidth,
            centerMode: centerMode,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )

        let newColX = columnX(at: result.columnIndex, columns: columns, gap: gap)
        let offsetDelta = activeColX - newColX

        activeColumnIndex = result.columnIndex

        let targetOffset = result.viewPos - Double(newColX)

        guard motion.animationsEnabled else {
            viewOffsetPixels = .static(CGFloat(targetOffset))
            activatePrevColumnOnRemoval = nil
            viewOffsetToRestore = nil
            selectionProgress = 0.0
            return
        }

        let now = animationClock?.now() ?? CACurrentMediaTime()
        let animation = SpringAnimation(
            from: currentOffset + Double(offsetDelta),
            to: targetOffset,
            initialVelocity: velocity,
            startTime: now,
            config: springConfig,
            displayRefreshRate: displayRefreshRate
        )
        viewOffsetPixels = .spring(animation)

        activatePrevColumnOnRemoval = nil
        viewOffsetToRestore = nil
        selectionProgress = 0.0
    }

    private mutating func endGestureWithoutSnap(currentOffset: Double) {
        viewOffsetPixels = .static(CGFloat(currentOffset))
        activatePrevColumnOnRemoval = nil
        viewOffsetToRestore = nil
        selectionProgress = 0.0
    }

}

