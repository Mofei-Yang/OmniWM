import AppKit
import Foundation
import Testing

@testable import OmniWM

private struct NavigationEngineLCG {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
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

private struct NavigationWindowSignature: Equatable {
    let pid: Int32
    let hiddenInTabbedMode: Bool
}

private struct NavigationColumnSignature: Equatable {
    let isTabbed: Bool
    let activeTileIdx: Int
    let windows: [NavigationWindowSignature]
}

private struct NavigationLayoutSignature: Equatable {
    let columns: [NavigationColumnSignature]
}

private enum NavigationSelectionSignature: Equatable {
    case none
    case window(pid: Int32)
    case column(index: Int)
}

private enum NavigationOpKind: CaseIterable {
    case moveByColumns
    case moveVertical
    case focusTarget
    case focusDownOrLeft
    case focusUpOrRight
    case focusColumnFirst
    case focusColumnLast
    case focusColumnIndex
    case focusWindowIndex
    case focusWindowTop
    case focusWindowBottom
}

private struct NavigationOperation {
    let kind: NavigationOpKind
    let direction: Direction?
    let step: Int
    let targetRowIndex: Int?
    let targetColumnIndex: Int
    let targetWindowIndex: Int
}

private struct NavigationDualEngines {
    let zigEngine: NiriLayoutEngine
    let legacyEngine: NiriLayoutEngine
    let workspaceId: WorkspaceDescriptor.ID
    let workingFrame: CGRect
    let gaps: CGFloat
}

private func navigationLayoutSignature(
    engine: NiriLayoutEngine,
    workspaceId: WorkspaceDescriptor.ID
) -> NavigationLayoutSignature {
    NavigationLayoutSignature(
        columns: engine.columns(in: workspaceId).map { column in
            NavigationColumnSignature(
                isTabbed: column.isTabbed,
                activeTileIdx: column.activeTileIdx,
                windows: column.windowNodes.map { window in
                    NavigationWindowSignature(
                        pid: window.handle.pid,
                        hiddenInTabbedMode: window.isHiddenInTabbedMode
                    )
                }
            )
        }
    )
}

private func navigationSelectionSignature(
    engine: NiriLayoutEngine,
    workspaceId: WorkspaceDescriptor.ID,
    state: ViewportState
) -> NavigationSelectionSignature {
    guard let selectedNodeId = state.selectedNodeId,
          let node = engine.findNode(by: selectedNodeId)
    else {
        return .none
    }

    if let window = node as? NiriWindow {
        return .window(pid: window.handle.pid)
    }

    if let column = node as? NiriContainer,
       let index = engine.columnIndex(of: column, in: workspaceId)
    {
        return .column(index: index)
    }

    return .none
}

private func navigationResultSignature(
    engine: NiriLayoutEngine,
    workspaceId: WorkspaceDescriptor.ID,
    node: NiriNode?
) -> NavigationSelectionSignature {
    guard let node else {
        return .none
    }

    if let window = node as? NiriWindow {
        return .window(pid: window.handle.pid)
    }

    if let column = node as? NiriContainer,
       let index = engine.columnIndex(of: column, in: workspaceId)
    {
        return .column(index: index)
    }

    return .none
}

private func assertNavigationInvariants(
    engine: NiriLayoutEngine,
    workspaceId: WorkspaceDescriptor.ID
) {
    let snapshot = NiriStateZigKernel.makeSnapshot(columns: engine.columns(in: workspaceId))
    #expect(NiriStateZigKernel.validate(snapshot: snapshot).isValid)

    for column in engine.columns(in: workspaceId) {
        if column.windowNodes.isEmpty {
            #expect(column.activeTileIdx == 0)
        } else {
            #expect(column.activeTileIdx >= 0)
            #expect(column.activeTileIdx < column.windowNodes.count)
        }
    }

    for (handle, node) in engine.handleToNode {
        #expect(engine.findNode(for: handle) === node)
    }
}

private func makeNavigationDualEngines(seed: UInt64) -> NavigationDualEngines {
    var rng = NavigationEngineLCG(seed: seed)

    let workspaceId = WorkspaceDescriptor.ID()
    let zigEngine = NiriLayoutEngine(maxWindowsPerColumn: 8, maxVisibleColumns: 3, infiniteLoop: rng.nextBool(0.5))
    let legacyEngine = NiriLayoutEngine(maxWindowsPerColumn: 8, maxVisibleColumns: 3, infiniteLoop: zigEngine.infiniteLoop)

    let zigRoot = NiriRoot(workspaceId: workspaceId)
    let legacyRoot = NiriRoot(workspaceId: workspaceId)
    zigEngine.roots[workspaceId] = zigRoot
    legacyEngine.roots[workspaceId] = legacyRoot

    let columnCount = rng.nextInt(2 ... 5)
    let baseSeed = UInt32(truncatingIfNeeded: seed)
    let pidBase = Int32(700_000 + Int(baseSeed % 10_000) * 10)

    for columnIndex in 0 ..< columnCount {
        let zigColumn = NiriContainer()
        let legacyColumn = NiriContainer()

        if rng.nextBool(0.35) {
            zigColumn.displayMode = .tabbed
            legacyColumn.displayMode = .tabbed
        }

        zigRoot.appendChild(zigColumn)
        legacyRoot.appendChild(legacyColumn)

        let rowCount = rng.nextInt(1 ... 4)
        for rowIndex in 0 ..< rowCount {
            let pid = pid_t(pidBase + Int32(columnIndex * 100 + rowIndex))

            let zigHandle = makeTestHandle(pid: pid)
            let legacyHandle = makeTestHandle(pid: pid)
            let zigWindow = NiriWindow(handle: zigHandle)
            let legacyWindow = NiriWindow(handle: legacyHandle)

            zigColumn.appendChild(zigWindow)
            legacyColumn.appendChild(legacyWindow)
            zigEngine.handleToNode[zigHandle] = zigWindow
            legacyEngine.handleToNode[legacyHandle] = legacyWindow
        }

        let activeTileIdx = rng.nextInt(0 ... rowCount - 1)
        zigColumn.setActiveTileIdx(activeTileIdx)
        legacyColumn.setActiveTileIdx(activeTileIdx)

        if zigColumn.isTabbed {
            zigEngine.updateTabbedColumnVisibility(column: zigColumn)
            legacyEngine.updateTabbedColumnVisibility(column: legacyColumn)
        }
    }

    return NavigationDualEngines(
        zigEngine: zigEngine,
        legacyEngine: legacyEngine,
        workspaceId: workspaceId,
        workingFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        gaps: 8
    )
}

private func currentNavigationSelection(
    engine: NiriLayoutEngine,
    workspaceId: WorkspaceDescriptor.ID,
    state: ViewportState
) -> NiriNode? {
    if let selectedNodeId = state.selectedNodeId,
       let selectedNode = engine.findNode(by: selectedNodeId)
    {
        return selectedNode
    }

    return engine.root(for: workspaceId)?.allWindows.first
}

private func randomDirection(rng: inout NavigationEngineLCG) -> Direction {
    switch rng.nextInt(0 ... 3) {
    case 0:
        return .left
    case 1:
        return .right
    case 2:
        return .up
    default:
        return .down
    }
}

private func makeNavigationOperation(
    kind: NavigationOpKind,
    engine: NiriLayoutEngine,
    workspaceId: WorkspaceDescriptor.ID,
    currentSelection: NiriNode,
    rng: inout NavigationEngineLCG
) -> NavigationOperation {
    switch kind {
    case .moveByColumns:
        return NavigationOperation(
            kind: kind,
            direction: nil,
            step: rng.nextBool() ? 1 : -1,
            targetRowIndex: rng.nextBool(0.25) ? Int.max : nil,
            targetColumnIndex: -1,
            targetWindowIndex: -1
        )

    case .moveVertical:
        return NavigationOperation(
            kind: kind,
            direction: rng.nextBool() ? .up : .down,
            step: 0,
            targetRowIndex: nil,
            targetColumnIndex: -1,
            targetWindowIndex: -1
        )

    case .focusTarget:
        return NavigationOperation(
            kind: kind,
            direction: randomDirection(rng: &rng),
            step: 0,
            targetRowIndex: nil,
            targetColumnIndex: -1,
            targetWindowIndex: -1
        )

    case .focusDownOrLeft,
         .focusUpOrRight,
         .focusColumnFirst,
         .focusColumnLast,
         .focusWindowTop,
         .focusWindowBottom:
        return NavigationOperation(
            kind: kind,
            direction: nil,
            step: 0,
            targetRowIndex: nil,
            targetColumnIndex: -1,
            targetWindowIndex: -1
        )

    case .focusColumnIndex:
        let columnCount = engine.columns(in: workspaceId).count
        let targetColumnIndex: Int = if columnCount > 0, rng.nextBool(0.8) {
            rng.nextInt(0 ... columnCount - 1)
        } else {
            -1
        }

        let outOfRangeColumnIndex = columnCount + rng.nextInt(1 ... 2)
        return NavigationOperation(
            kind: kind,
            direction: nil,
            step: 0,
            targetRowIndex: nil,
            targetColumnIndex: rng.nextBool(0.8) ? targetColumnIndex : outOfRangeColumnIndex,
            targetWindowIndex: -1
        )

    case .focusWindowIndex:
        let targetColumn = engine.column(of: currentSelection)
        let count = targetColumn?.windowNodes.count ?? 0

        let targetWindowIndex: Int = if count > 0, rng.nextBool(0.8) {
            rng.nextInt(0 ... count - 1)
        } else {
            0
        }

        let outOfRangeWindowIndex = max(1, count) + rng.nextInt(1 ... 2)
        return NavigationOperation(
            kind: kind,
            direction: nil,
            step: 0,
            targetRowIndex: nil,
            targetColumnIndex: -1,
            targetWindowIndex: rng.nextBool(0.8) ? targetWindowIndex : outOfRangeWindowIndex
        )
    }
}

private func executeNavigationOperation(
    engine: NiriLayoutEngine,
    workspaceId: WorkspaceDescriptor.ID,
    state: inout ViewportState,
    operation: NavigationOperation,
    currentSelection: NiriNode,
    workingFrame: CGRect,
    gaps: CGFloat
) -> NiriNode? {
    switch operation.kind {
    case .moveByColumns:
        return engine.moveSelectionByColumns(
            steps: operation.step,
            currentSelection: currentSelection,
            in: workspaceId,
            targetRowIndex: operation.targetRowIndex
        )

    case .moveVertical:
        guard let direction = operation.direction else { return nil }
        return engine.moveSelectionVertical(
            direction: direction,
            currentSelection: currentSelection,
            in: workspaceId
        )

    case .focusTarget:
        guard let direction = operation.direction else { return nil }
        return engine.focusTarget(
            direction: direction,
            currentSelection: currentSelection,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )

    case .focusDownOrLeft:
        return engine.focusDownOrLeft(
            currentSelection: currentSelection,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )

    case .focusUpOrRight:
        return engine.focusUpOrRight(
            currentSelection: currentSelection,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )

    case .focusColumnFirst:
        return engine.focusColumnFirst(
            currentSelection: currentSelection,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )

    case .focusColumnLast:
        return engine.focusColumnLast(
            currentSelection: currentSelection,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )

    case .focusColumnIndex:
        return engine.focusColumn(
            operation.targetColumnIndex,
            currentSelection: currentSelection,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )

    case .focusWindowIndex:
        return engine.focusWindowInColumn(
            operation.targetWindowIndex,
            currentSelection: currentSelection,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )

    case .focusWindowTop:
        return engine.focusWindowTop(
            currentSelection: currentSelection,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )

    case .focusWindowBottom:
        return engine.focusWindowBottom(
            currentSelection: currentSelection,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )
    }
}

@Suite(.serialized) struct NiriZigNavigationEngineParityTests {
    @Test func phase6BackendSwitchDeterministicNavigationParityCoversAllOps() {
        let dual = makeNavigationDualEngines(seed: 0x1234_5678_ABCD_EF01)
        let wsId = dual.workspaceId

        dual.zigEngine.backend = .zigContext
        dual.legacyEngine.backend = .legacyPlanApply

        var zigState = ViewportState()
        var legacyState = ViewportState()

        if let firstWindow = dual.zigEngine.root(for: wsId)?.allWindows.first {
            zigState.selectedNodeId = firstWindow.id
        }
        if let firstWindow = dual.legacyEngine.root(for: wsId)?.allWindows.first {
            legacyState.selectedNodeId = firstWindow.id
        }

        var rng = NavigationEngineLCG(seed: 0xCAFEBABE_F00D_FACE)
        let opOrder = NavigationOpKind.allCases

        for kind in opOrder {
            guard let zigCurrentSelection = currentNavigationSelection(
                engine: dual.zigEngine,
                workspaceId: wsId,
                state: zigState
            ),
                let legacyCurrentSelection = currentNavigationSelection(
                    engine: dual.legacyEngine,
                    workspaceId: wsId,
                    state: legacyState
                )
            else {
                Issue.record("missing current selection for deterministic navigation parity")
                return
            }

            let operation = makeNavigationOperation(
                kind: kind,
                engine: dual.zigEngine,
                workspaceId: wsId,
                currentSelection: zigCurrentSelection,
                rng: &rng
            )

            let zigTarget = executeNavigationOperation(
                engine: dual.zigEngine,
                workspaceId: wsId,
                state: &zigState,
                operation: operation,
                currentSelection: zigCurrentSelection,
                workingFrame: dual.workingFrame,
                gaps: dual.gaps
            )
            let legacyTarget = executeNavigationOperation(
                engine: dual.legacyEngine,
                workspaceId: wsId,
                state: &legacyState,
                operation: operation,
                currentSelection: legacyCurrentSelection,
                workingFrame: dual.workingFrame,
                gaps: dual.gaps
            )

            #expect(
                navigationResultSignature(engine: dual.zigEngine, workspaceId: wsId, node: zigTarget) ==
                    navigationResultSignature(engine: dual.legacyEngine, workspaceId: wsId, node: legacyTarget)
            )

            if let zigTarget {
                zigState.selectedNodeId = zigTarget.id
            }
            if let legacyTarget {
                legacyState.selectedNodeId = legacyTarget.id
            }

            #expect(
                navigationSelectionSignature(engine: dual.zigEngine, workspaceId: wsId, state: zigState) ==
                    navigationSelectionSignature(engine: dual.legacyEngine, workspaceId: wsId, state: legacyState)
            )
            #expect(
                navigationLayoutSignature(engine: dual.zigEngine, workspaceId: wsId) ==
                    navigationLayoutSignature(engine: dual.legacyEngine, workspaceId: wsId)
            )

            assertNavigationInvariants(engine: dual.zigEngine, workspaceId: wsId)
            assertNavigationInvariants(engine: dual.legacyEngine, workspaceId: wsId)
        }
    }

    @Test func phase6BackendSwitchRandomizedNavigationParityMatchesLegacyPlanApply() {
        let traceCount = 500
        let opsPerTrace = 20
        var rng = NavigationEngineLCG(seed: 0x0DDC_0FFE_EE11_4455)

        for trace in 0 ..< traceCount {
            let dual = makeNavigationDualEngines(seed: UInt64(90_000 + trace))
            let wsId = dual.workspaceId

            dual.zigEngine.backend = .zigContext
            dual.legacyEngine.backend = .legacyPlanApply

            var zigState = ViewportState()
            var legacyState = ViewportState()

            if let firstWindow = dual.zigEngine.root(for: wsId)?.allWindows.first {
                zigState.selectedNodeId = firstWindow.id
            }
            if let firstWindow = dual.legacyEngine.root(for: wsId)?.allWindows.first {
                legacyState.selectedNodeId = firstWindow.id
            }

            for _ in 0 ..< opsPerTrace {
                guard let zigCurrentSelection = currentNavigationSelection(
                    engine: dual.zigEngine,
                    workspaceId: wsId,
                    state: zigState
                ),
                    let legacyCurrentSelection = currentNavigationSelection(
                        engine: dual.legacyEngine,
                        workspaceId: wsId,
                        state: legacyState
                    )
                else {
                    Issue.record("missing current selection for randomized navigation parity")
                    return
                }

                let kind = NavigationOpKind.allCases[rng.nextInt(0 ... NavigationOpKind.allCases.count - 1)]
                let operation = makeNavigationOperation(
                    kind: kind,
                    engine: dual.zigEngine,
                    workspaceId: wsId,
                    currentSelection: zigCurrentSelection,
                    rng: &rng
                )

                let zigTarget = executeNavigationOperation(
                    engine: dual.zigEngine,
                    workspaceId: wsId,
                    state: &zigState,
                    operation: operation,
                    currentSelection: zigCurrentSelection,
                    workingFrame: dual.workingFrame,
                    gaps: dual.gaps
                )
                let legacyTarget = executeNavigationOperation(
                    engine: dual.legacyEngine,
                    workspaceId: wsId,
                    state: &legacyState,
                    operation: operation,
                    currentSelection: legacyCurrentSelection,
                    workingFrame: dual.workingFrame,
                    gaps: dual.gaps
                )

                #expect(
                    navigationResultSignature(engine: dual.zigEngine, workspaceId: wsId, node: zigTarget) ==
                        navigationResultSignature(engine: dual.legacyEngine, workspaceId: wsId, node: legacyTarget)
                )

                if let zigTarget {
                    zigState.selectedNodeId = zigTarget.id
                }
                if let legacyTarget {
                    legacyState.selectedNodeId = legacyTarget.id
                }

                #expect(
                    navigationSelectionSignature(engine: dual.zigEngine, workspaceId: wsId, state: zigState) ==
                        navigationSelectionSignature(engine: dual.legacyEngine, workspaceId: wsId, state: legacyState)
                )
                #expect(
                    navigationLayoutSignature(engine: dual.zigEngine, workspaceId: wsId) ==
                        navigationLayoutSignature(engine: dual.legacyEngine, workspaceId: wsId)
                )

                assertNavigationInvariants(engine: dual.zigEngine, workspaceId: wsId)
                assertNavigationInvariants(engine: dual.legacyEngine, workspaceId: wsId)
            }
        }
    }
}
