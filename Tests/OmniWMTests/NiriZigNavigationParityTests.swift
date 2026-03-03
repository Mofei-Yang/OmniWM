import Foundation
import QuartzCore
import Testing
import CZigLayout

@testable import OmniWM

private let navOK: Int32 = 0
private let navErrInvalidArgs: Int32 = -1
private let navErrOutOfRange: Int32 = -2

private func makeEmptyNavigationResult() -> OmniNiriNavigationResult {
    OmniNiriNavigationResult(
        has_target: 0,
        target_window_index: -1,
        update_source_active_tile: 0,
        source_column_index: -1,
        source_active_tile_idx: -1,
        update_target_active_tile: 0,
        target_column_index: -1,
        target_active_tile_idx: -1,
        refresh_tabbed_visibility_source: 0,
        refresh_tabbed_visibility_target: 0
    )
}

private struct RefSelection {
    let columnIndex: Int
    let rowIndex: Int
    let windowIndex: Int
}

private struct RefResolveOutcome {
    let rc: Int32
    let result: OmniNiriNavigationResult
}

private struct NavLCG {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1
        return state
    }

    mutating func nextBool(_ trueProbability: Double = 0.5) -> Bool {
        let value = Double(next() % 10_000) / 10_000.0
        return value < trueProbability
    }

    mutating func nextInt(_ range: ClosedRange<Int>) -> Int {
        let width = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(next() % width)
    }
}

private func percentile(_ samples: [Double], _ p: Double) -> Double {
    guard !samples.isEmpty else { return 0 }
    let sorted = samples.sorted()
    let idx = max(0, min(sorted.count - 1, Int(Double(sorted.count - 1) * p)))
    return sorted[idx]
}

private func parseRequiredSelection(
    snapshot: NiriStateZigKernel.Snapshot,
    request: NiriStateZigKernel.NavigationRequest
) -> RefSelection? {
    guard snapshot.columns.indices.contains(request.selectedColumnIndex),
          snapshot.windows.indices.contains(request.selectedWindowIndex)
    else {
        return nil
    }

    let column = snapshot.columns[request.selectedColumnIndex]
    let row = request.selectedRowIndex
    guard row >= 0, row < Int(column.window_count) else {
        return nil
    }

    let expectedWindowIndex = Int(column.window_start) + row
    guard expectedWindowIndex == request.selectedWindowIndex else {
        return nil
    }

    return RefSelection(
        columnIndex: request.selectedColumnIndex,
        rowIndex: row,
        windowIndex: request.selectedWindowIndex
    )
}

private func parseOptionalSelection(
    snapshot: NiriStateZigKernel.Snapshot,
    request: NiriStateZigKernel.NavigationRequest
) -> RefSelection? {
    guard request.selectedColumnIndex >= 0,
          request.selectedRowIndex >= 0,
          request.selectedWindowIndex >= 0
    else {
        return nil
    }

    return parseRequiredSelection(snapshot: snapshot, request: request)
}

private func wrappedIndex(_ index: Int, total: Int, infiniteLoop: Bool) -> Int? {
    guard total > 0 else { return nil }
    if infiniteLoop {
        return ((index % total) + total) % total
    }
    return (0 ..< total).contains(index) ? index : nil
}

private func setTarget(_ result: inout OmniNiriNavigationResult, windowIndex: Int) {
    result.has_target = 1
    result.target_window_index = Int64(windowIndex)
}

private func setSourceUpdate(_ result: inout OmniNiriNavigationResult, columnIndex: Int, rowIndex: Int) {
    result.update_source_active_tile = 1
    result.source_column_index = Int64(columnIndex)
    result.source_active_tile_idx = Int64(rowIndex)
}

private func setTargetUpdate(_ result: inout OmniNiriNavigationResult, columnIndex: Int, rowIndex: Int) {
    result.update_target_active_tile = 1
    result.target_column_index = Int64(columnIndex)
    result.target_active_tile_idx = Int64(rowIndex)
}

private func resolveMoveByColumns(
    snapshot: NiriStateZigKernel.Snapshot,
    selected: RefSelection,
    step: Int,
    targetRowIndex: Int,
    infiniteLoop: Bool,
    result: inout OmniNiriNavigationResult
) -> Int32 {
    guard targetRowIndex >= -1 else { return navErrInvalidArgs }

    if step == 0 {
        setTarget(&result, windowIndex: selected.windowIndex)
        return navOK
    }

    setSourceUpdate(&result, columnIndex: selected.columnIndex, rowIndex: selected.rowIndex)

    guard let targetColumnIndex = wrappedIndex(
        selected.columnIndex + step,
        total: snapshot.columns.count,
        infiniteLoop: infiniteLoop
    ) else {
        return navOK
    }

    let targetColumn = snapshot.columns[targetColumnIndex]
    let targetCount = Int(targetColumn.window_count)
    guard targetCount > 0 else { return navOK }

    let rawTargetRow: Int
    if targetRowIndex >= 0 {
        rawTargetRow = targetRowIndex
    } else {
        rawTargetRow = Int(targetColumn.active_tile_idx)
    }

    let clampedRow = min(max(0, rawTargetRow), targetCount - 1)
    let targetWindowIndex = Int(targetColumn.window_start) + clampedRow
    setTarget(&result, windowIndex: targetWindowIndex)
    return navOK
}

private func resolveMoveVertical(
    snapshot: NiriStateZigKernel.Snapshot,
    selected: RefSelection,
    step: Int,
    result: inout OmniNiriNavigationResult
) -> Int32 {
    guard step != 0 else { return navOK }

    let column = snapshot.columns[selected.columnIndex]
    let count = Int(column.window_count)
    guard count > 0 else { return navOK }

    if column.is_tabbed != 0 {
        let targetRow = Int(column.active_tile_idx) + step
        guard (0 ..< count).contains(targetRow) else { return navOK }
        setTarget(&result, windowIndex: Int(column.window_start) + targetRow)
        setTargetUpdate(&result, columnIndex: selected.columnIndex, rowIndex: targetRow)
        result.refresh_tabbed_visibility_target = 1
        return navOK
    }

    let targetRow = selected.rowIndex + step
    guard (0 ..< count).contains(targetRow) else { return navOK }
    setTarget(&result, windowIndex: Int(column.window_start) + targetRow)
    setTargetUpdate(&result, columnIndex: selected.columnIndex, rowIndex: targetRow)
    return navOK
}

private func resolveFocusColumnByIndex(
    snapshot: NiriStateZigKernel.Snapshot,
    targetColumnIndex: Int,
    selected: RefSelection?,
    result: inout OmniNiriNavigationResult
) -> Int32 {
    if let selected {
        setSourceUpdate(&result, columnIndex: selected.columnIndex, rowIndex: selected.rowIndex)
    }

    let targetColumn = snapshot.columns[targetColumnIndex]
    let targetCount = Int(targetColumn.window_count)
    guard targetCount > 0 else { return navOK }

    let targetRow = min(Int(targetColumn.active_tile_idx), targetCount - 1)
    setTarget(&result, windowIndex: Int(targetColumn.window_start) + targetRow)
    return navOK
}

private func resolveFocusWindowInColumn(
    snapshot: NiriStateZigKernel.Snapshot,
    selected: RefSelection,
    targetRow: Int,
    result: inout OmniNiriNavigationResult
) -> Int32 {
    let column = snapshot.columns[selected.columnIndex]
    let count = Int(column.window_count)
    guard (0 ..< count).contains(targetRow) else { return navErrOutOfRange }

    setTarget(&result, windowIndex: Int(column.window_start) + targetRow)
    setTargetUpdate(&result, columnIndex: selected.columnIndex, rowIndex: targetRow)
    if column.is_tabbed != 0 {
        result.refresh_tabbed_visibility_target = 1
    }
    return navOK
}

private func referenceResolve(
    snapshot: NiriStateZigKernel.Snapshot,
    request: NiriStateZigKernel.NavigationRequest
) -> RefResolveOutcome {
    var result = makeEmptyNavigationResult()

    switch request.op {
    case .moveByColumns:
        guard let selected = parseRequiredSelection(snapshot: snapshot, request: request) else {
            return RefResolveOutcome(rc: navErrOutOfRange, result: result)
        }
        let rc = resolveMoveByColumns(
            snapshot: snapshot,
            selected: selected,
            step: request.step,
            targetRowIndex: request.targetRowIndex,
            infiniteLoop: request.infiniteLoop,
            result: &result
        )
        return RefResolveOutcome(rc: rc, result: result)

    case .moveVertical:
        guard let direction = request.direction,
              let step = direction.secondaryStep(for: request.orientation)
        else {
            return RefResolveOutcome(rc: navOK, result: result)
        }
        guard let selected = parseRequiredSelection(snapshot: snapshot, request: request) else {
            return RefResolveOutcome(rc: navErrOutOfRange, result: result)
        }
        let rc = resolveMoveVertical(
            snapshot: snapshot,
            selected: selected,
            step: step,
            result: &result
        )
        return RefResolveOutcome(rc: rc, result: result)

    case .focusTarget:
        guard let direction = request.direction else {
            return RefResolveOutcome(rc: navErrInvalidArgs, result: result)
        }
        guard let selected = parseRequiredSelection(snapshot: snapshot, request: request) else {
            return RefResolveOutcome(rc: navErrOutOfRange, result: result)
        }

        if let step = direction.primaryStep(for: request.orientation) {
            let rc = resolveMoveByColumns(
                snapshot: snapshot,
                selected: selected,
                step: step,
                targetRowIndex: -1,
                infiniteLoop: request.infiniteLoop,
                result: &result
            )
            return RefResolveOutcome(rc: rc, result: result)
        }

        if let step = direction.secondaryStep(for: request.orientation) {
            let rc = resolveMoveVertical(
                snapshot: snapshot,
                selected: selected,
                step: step,
                result: &result
            )
            return RefResolveOutcome(rc: rc, result: result)
        }

        return RefResolveOutcome(rc: navOK, result: result)

    case .focusDownOrLeft:
        guard let selected = parseRequiredSelection(snapshot: snapshot, request: request) else {
            return RefResolveOutcome(rc: navErrOutOfRange, result: result)
        }

        let verticalRc = resolveMoveVertical(
            snapshot: snapshot,
            selected: selected,
            step: Direction.down.secondaryStep(for: .horizontal) ?? 0,
            result: &result
        )
        guard verticalRc == navOK else {
            return RefResolveOutcome(rc: verticalRc, result: result)
        }

        if result.has_target != 0 {
            return RefResolveOutcome(rc: navOK, result: result)
        }

        let horizontalRc = resolveMoveByColumns(
            snapshot: snapshot,
            selected: selected,
            step: -1,
            targetRowIndex: Int.max,
            infiniteLoop: request.infiniteLoop,
            result: &result
        )
        return RefResolveOutcome(rc: horizontalRc, result: result)

    case .focusUpOrRight:
        guard let selected = parseRequiredSelection(snapshot: snapshot, request: request) else {
            return RefResolveOutcome(rc: navErrOutOfRange, result: result)
        }

        let verticalRc = resolveMoveVertical(
            snapshot: snapshot,
            selected: selected,
            step: Direction.up.secondaryStep(for: .horizontal) ?? 0,
            result: &result
        )
        guard verticalRc == navOK else {
            return RefResolveOutcome(rc: verticalRc, result: result)
        }

        if result.has_target != 0 {
            return RefResolveOutcome(rc: navOK, result: result)
        }

        let horizontalRc = resolveMoveByColumns(
            snapshot: snapshot,
            selected: selected,
            step: 1,
            targetRowIndex: -1,
            infiniteLoop: request.infiniteLoop,
            result: &result
        )
        return RefResolveOutcome(rc: horizontalRc, result: result)

    case .focusColumnFirst:
        guard !snapshot.columns.isEmpty else {
            return RefResolveOutcome(rc: navOK, result: result)
        }
        let selected = parseOptionalSelection(snapshot: snapshot, request: request)
        let rc = resolveFocusColumnByIndex(
            snapshot: snapshot,
            targetColumnIndex: 0,
            selected: selected,
            result: &result
        )
        return RefResolveOutcome(rc: rc, result: result)

    case .focusColumnLast:
        guard !snapshot.columns.isEmpty else {
            return RefResolveOutcome(rc: navOK, result: result)
        }
        let selected = parseOptionalSelection(snapshot: snapshot, request: request)
        let rc = resolveFocusColumnByIndex(
            snapshot: snapshot,
            targetColumnIndex: snapshot.columns.count - 1,
            selected: selected,
            result: &result
        )
        return RefResolveOutcome(rc: rc, result: result)

    case .focusColumnIndex:
        guard !snapshot.columns.isEmpty else {
            return RefResolveOutcome(rc: navOK, result: result)
        }
        guard snapshot.columns.indices.contains(request.targetColumnIndex) else {
            return RefResolveOutcome(rc: navErrOutOfRange, result: result)
        }
        let selected = parseOptionalSelection(snapshot: snapshot, request: request)
        let rc = resolveFocusColumnByIndex(
            snapshot: snapshot,
            targetColumnIndex: request.targetColumnIndex,
            selected: selected,
            result: &result
        )
        return RefResolveOutcome(rc: rc, result: result)

    case .focusWindowIndex:
        guard let selected = parseRequiredSelection(snapshot: snapshot, request: request) else {
            return RefResolveOutcome(rc: navErrOutOfRange, result: result)
        }
        let rc = resolveFocusWindowInColumn(
            snapshot: snapshot,
            selected: selected,
            targetRow: request.targetWindowIndex,
            result: &result
        )
        return RefResolveOutcome(rc: rc, result: result)

    case .focusWindowTop:
        guard let selected = parseRequiredSelection(snapshot: snapshot, request: request) else {
            return RefResolveOutcome(rc: navErrOutOfRange, result: result)
        }
        let rc = resolveFocusWindowInColumn(
            snapshot: snapshot,
            selected: selected,
            targetRow: 0,
            result: &result
        )
        return RefResolveOutcome(rc: rc, result: result)

    case .focusWindowBottom:
        guard let selected = parseRequiredSelection(snapshot: snapshot, request: request) else {
            return RefResolveOutcome(rc: navErrOutOfRange, result: result)
        }
        let column = snapshot.columns[selected.columnIndex]
        let count = Int(column.window_count)
        guard count > 0 else {
            return RefResolveOutcome(rc: navOK, result: result)
        }
        let rc = resolveFocusWindowInColumn(
            snapshot: snapshot,
            selected: selected,
            targetRow: count - 1,
            result: &result
        )
        return RefResolveOutcome(rc: rc, result: result)
    }
}

private func assertResolverParity(
    snapshot: NiriStateZigKernel.Snapshot,
    request: NiriStateZigKernel.NavigationRequest
) {
    let reference = referenceResolve(snapshot: snapshot, request: request)
    let zig = NiriStateZigKernel.resolveNavigation(snapshot: snapshot, request: request)

    assertResolverOutcomeParity(reference: reference, zig: zig)
}

private func assertResolverOutcomeParity(
    reference: RefResolveOutcome,
    zig: NiriStateZigKernel.NavigationOutcome
) {
    #expect(zig.rc == reference.rc)
    #expect(zig.result.has_target == reference.result.has_target)
    #expect(zig.result.target_window_index == reference.result.target_window_index)
    #expect(zig.result.update_source_active_tile == reference.result.update_source_active_tile)
    #expect(zig.result.source_column_index == reference.result.source_column_index)
    #expect(zig.result.source_active_tile_idx == reference.result.source_active_tile_idx)
    #expect(zig.result.update_target_active_tile == reference.result.update_target_active_tile)
    #expect(zig.result.target_column_index == reference.result.target_column_index)
    #expect(zig.result.target_active_tile_idx == reference.result.target_active_tile_idx)
    #expect(zig.result.refresh_tabbed_visibility_source == reference.result.refresh_tabbed_visibility_source)
    #expect(zig.result.refresh_tabbed_visibility_target == reference.result.refresh_tabbed_visibility_target)
}

private func applyNavigationResultToSnapshot(
    _ result: OmniNiriNavigationResult,
    snapshot: inout NiriStateZigKernel.Snapshot
) {
    func applyActiveTile(columnRaw: Int64, rowRaw: Int64, enabled: UInt8) {
        guard enabled != 0,
              let columnIndex = Int(exactly: columnRaw),
              let rowIndex = Int(exactly: rowRaw),
              snapshot.columns.indices.contains(columnIndex)
        else {
            return
        }

        let count = Int(snapshot.columns[columnIndex].window_count)
        guard count > 0 else {
            snapshot.columns[columnIndex].active_tile_idx = 0
            return
        }

        let clampedRow = rowIndex.clamped(to: 0 ... (count - 1))
        snapshot.columns[columnIndex].active_tile_idx = clampedRow
    }

    applyActiveTile(
        columnRaw: result.source_column_index,
        rowRaw: result.source_active_tile_idx,
        enabled: result.update_source_active_tile
    )
    applyActiveTile(
        columnRaw: result.target_column_index,
        rowRaw: result.target_active_tile_idx,
        enabled: result.update_target_active_tile
    )
}

private func nextSelectedWindow(
    current: NiriWindow,
    result: OmniNiriNavigationResult,
    snapshot: NiriStateZigKernel.Snapshot
) -> NiriWindow {
    guard result.has_target != 0,
          let targetIndex = Int(exactly: result.target_window_index),
          snapshot.windowEntries.indices.contains(targetIndex)
    else {
        return current
    }

    return snapshot.windowEntries[targetIndex].window
}

private func makeDeterministicSnapshot() -> (
    snapshot: NiriStateZigKernel.Snapshot,
    windows: [[NiriWindow]]
) {
    let engine = NiriLayoutEngine(maxWindowsPerColumn: 8)
    let workspaceId = WorkspaceDescriptor.ID()
    let root = NiriRoot(workspaceId: workspaceId)
    engine.roots[workspaceId] = root

    var windows: [[NiriWindow]] = []
    for columnIndex in 0 ..< 3 {
        let column = NiriContainer()
        if columnIndex == 1 {
            column.displayMode = .tabbed
        }
        root.appendChild(column)

        var colWindows: [NiriWindow] = []
        let rows = columnIndex == 2 ? 2 : 3
        for row in 0 ..< rows {
            let handle = makeTestHandle(pid: pid_t(40_000 + columnIndex * 100 + row))
            let window = NiriWindow(handle: handle)
            column.appendChild(window)
            engine.handleToNode[handle] = window
            colWindows.append(window)
        }

        if columnIndex == 0 {
            column.setActiveTileIdx(1)
        } else if columnIndex == 1 {
            column.setActiveTileIdx(1)
        } else {
            column.setActiveTileIdx(0)
        }

        windows.append(colWindows)
    }

    let snapshot = NiriStateZigKernel.makeSnapshot(columns: engine.columns(in: workspaceId))
    return (snapshot, windows)
}

private func makeRandomSnapshot(seed: UInt64) -> (
    snapshot: NiriStateZigKernel.Snapshot,
    windows: [NiriWindow]
) {
    var rng = NavLCG(seed: seed)

    let engine = NiriLayoutEngine(maxWindowsPerColumn: 8)
    let workspaceId = WorkspaceDescriptor.ID()
    let root = NiriRoot(workspaceId: workspaceId)
    engine.roots[workspaceId] = root

    let columnCount = rng.nextInt(1 ... 6)
    var allWindows: [NiriWindow] = []

    for col in 0 ..< columnCount {
        let column = NiriContainer()
        if rng.nextBool(0.35) {
            column.displayMode = .tabbed
        }
        root.appendChild(column)

        let rowCount = rng.nextInt(1 ... 5)
        for row in 0 ..< rowCount {
            let handle = makeTestHandle(pid: pid_t(50_000 + col * 100 + row))
            let window = NiriWindow(handle: handle)
            column.appendChild(window)
            engine.handleToNode[handle] = window
            allWindows.append(window)
        }

        if !column.windowNodes.isEmpty {
            column.setActiveTileIdx(rng.nextInt(0 ... column.windowNodes.count - 1))
        }
    }

    let snapshot = NiriStateZigKernel.makeSnapshot(columns: engine.columns(in: workspaceId))
    return (snapshot, allWindows)
}

private func makeRandomRequest(
    snapshot: NiriStateZigKernel.Snapshot,
    currentSelection: NiriNode,
    rng: inout NavLCG
) -> NiriStateZigKernel.NavigationRequest {
    let selection = NiriStateZigKernel.makeSelectionContext(node: currentSelection, snapshot: snapshot)
    let opIndex = rng.nextInt(0 ... 10)

    let op: NiriStateZigKernel.NavigationOp = switch opIndex {
    case 0: .moveByColumns
    case 1: .moveVertical
    case 2: .focusTarget
    case 3: .focusDownOrLeft
    case 4: .focusUpOrRight
    case 5: .focusColumnFirst
    case 6: .focusColumnLast
    case 7: .focusColumnIndex
    case 8: .focusWindowIndex
    case 9: .focusWindowTop
    default: .focusWindowBottom
    }

    let randomDirection: Direction = switch rng.nextInt(0 ... 3) {
    case 0: .left
    case 1: .right
    case 2: .up
    default: .down
    }
    let randomOrientation: Monitor.Orientation = rng.nextBool() ? .horizontal : .vertical

    switch op {
    case .moveByColumns:
        return NiriStateZigKernel.NavigationRequest(
            op: op,
            selection: selection,
            infiniteLoop: rng.nextBool(0.4),
            step: rng.nextBool() ? 1 : -1,
            targetRowIndex: rng.nextBool(0.7) ? -1 : Int.max
        )

    case .moveVertical:
        return NiriStateZigKernel.NavigationRequest(
            op: op,
            selection: selection,
            direction: randomDirection,
            orientation: randomOrientation
        )

    case .focusTarget:
        return NiriStateZigKernel.NavigationRequest(
            op: op,
            selection: selection,
            direction: randomDirection,
            orientation: randomOrientation,
            infiniteLoop: rng.nextBool(0.4)
        )

    case .focusDownOrLeft, .focusUpOrRight:
        return NiriStateZigKernel.NavigationRequest(
            op: op,
            selection: selection,
            infiniteLoop: rng.nextBool(0.4)
        )

    case .focusColumnFirst, .focusColumnLast:
        return NiriStateZigKernel.NavigationRequest(
            op: op,
            selection: selection,
            infiniteLoop: rng.nextBool(0.4)
        )

    case .focusColumnIndex:
        let target: Int = if rng.nextBool(0.8) {
            rng.nextInt(0 ... snapshot.columns.count - 1)
        } else {
            snapshot.columns.count + rng.nextInt(1 ... 3)
        }
        return NiriStateZigKernel.NavigationRequest(
            op: op,
            selection: selection,
            targetColumnIndex: target
        )

    case .focusWindowIndex:
        let selectedColumn = selection?.selectedColumnIndex ?? 0
        let count = snapshot.columns.indices.contains(selectedColumn) ? Int(snapshot.columns[selectedColumn].window_count) : 0
        let target: Int = if count > 0, rng.nextBool(0.8) {
            rng.nextInt(0 ... count - 1)
        } else {
            max(1, count) + rng.nextInt(1 ... 3)
        }
        return NiriStateZigKernel.NavigationRequest(
            op: op,
            selection: selection,
            targetWindowIndex: target
        )

    case .focusWindowTop, .focusWindowBottom:
        return NiriStateZigKernel.NavigationRequest(
            op: op,
            selection: selection
        )
    }
}

@Suite(.serialized) struct NiriZigNavigationParityTests {
    @Test func deterministicFixturesMatchReferenceModel() {
        let fixture = makeDeterministicSnapshot()
        let snapshot = fixture.snapshot

        let s0 = NiriStateZigKernel.makeSelectionContext(node: fixture.windows[0][1], snapshot: snapshot)
        let s1 = NiriStateZigKernel.makeSelectionContext(node: fixture.windows[1][1], snapshot: snapshot)
        #expect(s0 != nil)
        #expect(s1 != nil)
        guard let s0, let s1 else { return }

        let requests: [NiriStateZigKernel.NavigationRequest] = [
            .init(op: .moveByColumns, selection: s0, infiniteLoop: false, step: 1),
            .init(op: .moveVertical, selection: s0, direction: .up, orientation: .horizontal),
            .init(op: .moveVertical, selection: s1, direction: .up, orientation: .horizontal),
            .init(op: .focusTarget, selection: s0, direction: .left, orientation: .horizontal, infiniteLoop: true),
            .init(op: .focusTarget, selection: s0, direction: .up, orientation: .horizontal),
            .init(op: .focusDownOrLeft, selection: s0, infiniteLoop: true),
            .init(op: .focusUpOrRight, selection: s0, infiniteLoop: true),
            .init(op: .focusColumnFirst, selection: s0),
            .init(op: .focusColumnLast, selection: s0),
            .init(op: .focusColumnIndex, selection: s0, targetColumnIndex: 2),
            .init(op: .focusWindowIndex, selection: s0, targetWindowIndex: 2),
            .init(op: .focusWindowTop, selection: s0),
            .init(op: .focusWindowBottom, selection: s0)
        ]

        for request in requests {
            assertResolverParity(snapshot: snapshot, request: request)
        }
    }

    @Test func randomizedParityMatchesReferenceModel() {
        // Supplemental non-stateful fuzzing; the main Phase 2 gate is
        // statefulSequenceParityMatchesReferenceModel().
        var rng = NavLCG(seed: 0x1234_5678_ABCD_EF01)

        for iteration in 0 ..< 250 {
            let scenario = makeRandomSnapshot(seed: UInt64(1000 + iteration))
            let snapshot = scenario.snapshot
            #expect(!scenario.windows.isEmpty)
            guard !scenario.windows.isEmpty else { continue }

            for _ in 0 ..< 50 {
                let currentWindow = scenario.windows[rng.nextInt(0 ... scenario.windows.count - 1)]
                let request = makeRandomRequest(snapshot: snapshot, currentSelection: currentWindow, rng: &rng)
                assertResolverParity(snapshot: snapshot, request: request)
            }
        }
    }

    @Test func statefulSequenceParityMatchesReferenceModel() {
        let traceCount = 10_000
        let opsPerTrace = 16
        var rng = NavLCG(seed: 0xFEED_FACE_CAFE_BEEF)

        for trace in 0 ..< traceCount {
            let scenario = makeRandomSnapshot(seed: UInt64(9_000 + trace))
            #expect(!scenario.windows.isEmpty)
            guard !scenario.windows.isEmpty else { continue }

            var zigSnapshot = scenario.snapshot
            var refSnapshot = scenario.snapshot
            var currentSelection = scenario.windows[rng.nextInt(0 ... scenario.windows.count - 1)]

            for _ in 0 ..< opsPerTrace {
                let request = makeRandomRequest(
                    snapshot: zigSnapshot,
                    currentSelection: currentSelection,
                    rng: &rng
                )

                let reference = referenceResolve(snapshot: refSnapshot, request: request)
                let zig = NiriStateZigKernel.resolveNavigation(snapshot: zigSnapshot, request: request)
                assertResolverOutcomeParity(reference: reference, zig: zig)

                applyNavigationResultToSnapshot(reference.result, snapshot: &refSnapshot)
                applyNavigationResultToSnapshot(zig.result, snapshot: &zigSnapshot)

                currentSelection = nextSelectedWindow(
                    current: currentSelection,
                    result: zig.result,
                    snapshot: zigSnapshot
                )
            }
        }
    }

    @Test func navigationKernelBenchmarkHarnessP95() throws {
        let scenario = makeRandomSnapshot(seed: 0xA11C_E551)
        let snapshot = scenario.snapshot
        let windows = scenario.windows
        #expect(!windows.isEmpty)
        guard !windows.isEmpty else { return }

        var rng = NavLCG(seed: 0xD00D_FEED)
        var requests: [NiriStateZigKernel.NavigationRequest] = []
        requests.reserveCapacity(10_000)

        for _ in 0 ..< 10_000 {
            let current = windows[rng.nextInt(0 ... windows.count - 1)]
            requests.append(makeRandomRequest(snapshot: snapshot, currentSelection: current, rng: &rng))
        }

        var samples: [Double] = []
        samples.reserveCapacity(requests.count)

        for request in requests {
            let t0 = CACurrentMediaTime()
            _ = NiriStateZigKernel.resolveNavigation(snapshot: snapshot, request: request)
            samples.append(CACurrentMediaTime() - t0)
        }

        let p95 = percentile(samples, 0.95)
        print(String(format: "Niri navigation benchmark p95 (zig resolver): %.9f", p95))

        let baseline = try BenchmarkBaselines.loadPhase2Navigation()
        let perfLimit = baseline.navigation_p95_sec * 1.10

        #expect(p95 > 0)
        #expect(p95 <= perfLimit)
    }
}
