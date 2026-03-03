import Foundation
import QuartzCore
import Testing

@testable import OmniWM

private struct MutationLCG {
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

private func proportionalSignature(_ value: ProportionalSize) -> (kind: Int, value: Double) {
    switch value {
    case let .proportion(v):
        return (0, Double(v))
    case let .fixed(v):
        return (1, Double(v))
    }
}

private func weightedSignature(_ value: WeightedSize) -> (kind: Int, value: Double) {
    switch value {
    case let .auto(weight: w):
        return (0, Double(w))
    case let .fixed(v):
        return (1, Double(v))
    }
}

private struct WindowSignature: Equatable {
    let pid: Int32
    let size: Double
    let heightKind: Int
    let heightValue: Double
}

private struct ColumnSignature: Equatable {
    let isTabbed: Bool
    let activeTileIdx: Int
    let widthKind: Int
    let widthValue: Double
    let isFullWidth: Bool
    let savedWidthKind: Int
    let savedWidthValue: Double
    let windows: [WindowSignature]
}

private struct LayoutSignature: Equatable {
    let columns: [ColumnSignature]
}

private func layoutSignature(
    engine: NiriLayoutEngine,
    workspaceId: WorkspaceDescriptor.ID
) -> LayoutSignature {
    let columns = engine.columns(in: workspaceId).map { column -> ColumnSignature in
        let width = proportionalSignature(column.width)
        let savedWidth = proportionalSignature(column.savedWidth ?? .proportion(-1))
        let windows = column.windowNodes.map { window in
            let height = weightedSignature(window.height)
            return WindowSignature(
                pid: window.handle.pid,
                size: Double(window.size),
                heightKind: height.kind,
                heightValue: height.value
            )
        }

        return ColumnSignature(
            isTabbed: column.isTabbed,
            activeTileIdx: column.activeTileIdx,
            widthKind: width.kind,
            widthValue: width.value,
            isFullWidth: column.isFullWidth,
            savedWidthKind: savedWidth.kind,
            savedWidthValue: savedWidth.value,
            windows: windows
        )
    }

    return LayoutSignature(columns: columns)
}

private func assertMutationOutcomeParity(
    zig: NiriStateZigKernel.MutationOutcome,
    reference: NiriStateZigKernel.MutationOutcome
) {
    #expect(zig.rc == reference.rc)
    #expect(zig.applied == reference.applied)
    #expect(zig.targetWindowIndex == reference.targetWindowIndex)
    #expect(zig.edits.count == reference.edits.count)
    guard zig.edits.count == reference.edits.count else { return }

    for idx in 0 ..< zig.edits.count {
        let lhs = zig.edits[idx]
        let rhs = reference.edits[idx]
        #expect(lhs.kind == rhs.kind)
        #expect(lhs.subjectIndex == rhs.subjectIndex)
        #expect(lhs.relatedIndex == rhs.relatedIndex)
        #expect(lhs.valueA == rhs.valueA)
        #expect(lhs.valueB == rhs.valueB)
    }
}

private func applyMutationOutcome(
    engine: NiriLayoutEngine,
    workspaceId: WorkspaceDescriptor.ID,
    state: inout ViewportState,
    snapshot: NiriStateZigKernel.Snapshot,
    outcome: NiriStateZigKernel.MutationOutcome,
    workingFrame: CGRect,
    gaps: CGFloat
) -> Bool {
    guard outcome.rc == 0 else { return false }
    guard outcome.applied else { return false }

    let applyOutcome = NiriStateZigMutationApplier.apply(
        outcome: outcome,
        snapshot: snapshot,
        engine: engine
    )
    guard applyOutcome.applied else { return false }

    if let delegated = applyOutcome.delegatedMoveColumn {
        return engine.moveColumn(
            delegated.column,
            direction: delegated.direction,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )
    }

    return true
}

private func assertMutationInvariants(
    engine: NiriLayoutEngine,
    workspaceId: WorkspaceDescriptor.ID
) {
    let snapshot = NiriStateZigKernel.makeSnapshot(columns: engine.columns(in: workspaceId))
    let validation = NiriStateZigKernel.validate(snapshot: snapshot)
    #expect(validation.isValid)

    if let root = engine.root(for: workspaceId) {
        #expect(root.allWindows.count == snapshot.windowEntries.count)
        for column in root.columns {
            if column.windowNodes.isEmpty {
                #expect(column.activeTileIdx == 0)
            } else {
                #expect(column.activeTileIdx >= 0)
                #expect(column.activeTileIdx < column.windowNodes.count)
            }
        }
    }
}

private struct DualEngines {
    let zigEngine: NiriLayoutEngine
    let referenceEngine: NiriLayoutEngine
    let workspaceId: WorkspaceDescriptor.ID
    let workingFrame: CGRect
    let gaps: CGFloat
}

private func makeDualEngines(seed: UInt64) -> DualEngines {
    var rng = MutationLCG(seed: seed)
    let workspaceId = WorkspaceDescriptor.ID()
    let maxWindowsPerColumn = 8
    let infiniteLoop = rng.nextBool(0.5)

    let zigEngine = NiriLayoutEngine(maxWindowsPerColumn: maxWindowsPerColumn, infiniteLoop: infiniteLoop)
    let referenceEngine = NiriLayoutEngine(maxWindowsPerColumn: maxWindowsPerColumn, infiniteLoop: infiniteLoop)
    let zigRoot = NiriRoot(workspaceId: workspaceId)
    let refRoot = NiriRoot(workspaceId: workspaceId)
    zigEngine.roots[workspaceId] = zigRoot
    referenceEngine.roots[workspaceId] = refRoot

    let columnCount = rng.nextInt(2 ... 5)
    for columnIndex in 0 ..< columnCount {
        let zigColumn = NiriContainer()
        let refColumn = NiriContainer()
        let isTabbed = rng.nextBool(0.35)
        zigColumn.displayMode = isTabbed ? .tabbed : .normal
        refColumn.displayMode = isTabbed ? .tabbed : .normal

        let fullWidth = rng.nextBool(0.25)
        let widthValue = CGFloat(rng.nextInt(2 ... 8)) / 10.0
        let savedWidthValue = CGFloat(rng.nextInt(2 ... 8)) / 10.0
        zigColumn.width = .proportion(widthValue)
        refColumn.width = .proportion(widthValue)
        zigColumn.isFullWidth = fullWidth
        refColumn.isFullWidth = fullWidth
        if rng.nextBool(0.5) {
            zigColumn.savedWidth = .proportion(savedWidthValue)
            refColumn.savedWidth = .proportion(savedWidthValue)
        }

        zigRoot.appendChild(zigColumn)
        refRoot.appendChild(refColumn)

        let windowCount = rng.nextInt(1 ... 4)
        for row in 0 ..< windowCount {
            let pid = pid_t(70_000 + columnIndex * 100 + row)
            let zigHandle = makeTestHandle(pid: pid)
            let refHandle = makeTestHandle(pid: pid)
            let zigWindow = NiriWindow(handle: zigHandle)
            let refWindow = NiriWindow(handle: refHandle)

            let size = CGFloat(rng.nextInt(5 ... 20)) / 10.0
            zigWindow.size = size
            refWindow.size = size
            if rng.nextBool(0.3) {
                let fixedHeight = CGFloat(rng.nextInt(3 ... 12)) / 10.0
                zigWindow.height = .fixed(fixedHeight)
                refWindow.height = .fixed(fixedHeight)
            } else {
                let autoWeight = CGFloat(rng.nextInt(5 ... 20)) / 10.0
                zigWindow.height = .auto(weight: autoWeight)
                refWindow.height = .auto(weight: autoWeight)
            }

            zigColumn.appendChild(zigWindow)
            refColumn.appendChild(refWindow)
            zigEngine.handleToNode[zigHandle] = zigWindow
            referenceEngine.handleToNode[refHandle] = refWindow
        }

        let activeTile = rng.nextInt(0 ... max(0, windowCount - 1))
        zigColumn.setActiveTileIdx(activeTile)
        refColumn.setActiveTileIdx(activeTile)
    }

    return DualEngines(
        zigEngine: zigEngine,
        referenceEngine: referenceEngine,
        workspaceId: workspaceId,
        workingFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        gaps: 8
    )
}

private func makeRandomMutationRequest(
    snapshot: NiriStateZigKernel.Snapshot,
    maxWindowsPerColumn: Int,
    infiniteLoop: Bool,
    rng: inout MutationLCG
) -> NiriStateZigKernel.MutationRequest {
    let sourceWindowIndex = rng.nextInt(0 ... snapshot.windowEntries.count - 1)
    let targetWindowIndex = rng.nextInt(0 ... snapshot.windowEntries.count - 1)
    let opChoice = rng.nextInt(0 ... 5)

    switch opChoice {
    case 0:
        return .init(
            op: .moveWindowVertical,
            sourceWindowIndex: sourceWindowIndex,
            direction: rng.nextBool() ? .up : .down,
            infiniteLoop: infiniteLoop,
            maxWindowsPerColumn: maxWindowsPerColumn
        )
    case 1:
        return .init(
            op: .swapWindowVertical,
            sourceWindowIndex: sourceWindowIndex,
            direction: rng.nextBool() ? .up : .down,
            infiniteLoop: infiniteLoop,
            maxWindowsPerColumn: maxWindowsPerColumn
        )
    case 2:
        return .init(
            op: .moveWindowHorizontal,
            sourceWindowIndex: sourceWindowIndex,
            direction: rng.nextBool() ? .left : .right,
            infiniteLoop: infiniteLoop,
            maxWindowsPerColumn: maxWindowsPerColumn
        )
    case 3:
        return .init(
            op: .swapWindowHorizontal,
            sourceWindowIndex: sourceWindowIndex,
            direction: rng.nextBool() ? .left : .right,
            infiniteLoop: infiniteLoop,
            maxWindowsPerColumn: maxWindowsPerColumn
        )
    case 4:
        return .init(
            op: .swapWindowsByMove,
            sourceWindowIndex: sourceWindowIndex,
            targetWindowIndex: targetWindowIndex,
            infiniteLoop: infiniteLoop,
            maxWindowsPerColumn: maxWindowsPerColumn
        )
    default:
        return .init(
            op: .insertWindowByMove,
            sourceWindowIndex: sourceWindowIndex,
            targetWindowIndex: targetWindowIndex,
            infiniteLoop: infiniteLoop,
            insertPosition: rng.nextBool() ? .before : .after,
            maxWindowsPerColumn: maxWindowsPerColumn
        )
    }
}

@Suite(.serialized) struct NiriZigWindowOpsParityTests {
    @Test func deterministicFixturesMatchReferenceModel() {
        let dual = makeDualEngines(seed: 0xA55A_A55A_1234_5678)
        let zigEngine = dual.zigEngine
        let refEngine = dual.referenceEngine
        let wsId = dual.workspaceId
        var zigState = ViewportState()
        var refState = ViewportState()

        let initialSnapshot = NiriStateZigKernel.makeSnapshot(columns: zigEngine.columns(in: wsId))
        #expect(initialSnapshot.windowEntries.count >= 3)
        guard initialSnapshot.windowEntries.count >= 3 else { return }

        let requests: [NiriStateZigKernel.MutationRequest] = [
            .init(op: .moveWindowVertical, sourceWindowIndex: 0, direction: .up, infiniteLoop: zigEngine.infiniteLoop, maxWindowsPerColumn: zigEngine.maxWindowsPerColumn),
            .init(op: .swapWindowVertical, sourceWindowIndex: 1, direction: .down, infiniteLoop: zigEngine.infiniteLoop, maxWindowsPerColumn: zigEngine.maxWindowsPerColumn),
            .init(op: .moveWindowHorizontal, sourceWindowIndex: 0, direction: .right, infiniteLoop: zigEngine.infiniteLoop, maxWindowsPerColumn: zigEngine.maxWindowsPerColumn),
            .init(op: .swapWindowHorizontal, sourceWindowIndex: 1, direction: .left, infiniteLoop: zigEngine.infiniteLoop, maxWindowsPerColumn: zigEngine.maxWindowsPerColumn),
            .init(op: .swapWindowsByMove, sourceWindowIndex: 0, targetWindowIndex: 2, infiniteLoop: zigEngine.infiniteLoop, maxWindowsPerColumn: zigEngine.maxWindowsPerColumn),
            .init(op: .insertWindowByMove, sourceWindowIndex: 1, targetWindowIndex: 0, infiniteLoop: zigEngine.infiniteLoop, insertPosition: .after, maxWindowsPerColumn: zigEngine.maxWindowsPerColumn),
        ]

        for request in requests {
            let zigSnapshot = NiriStateZigKernel.makeSnapshot(columns: zigEngine.columns(in: wsId))
            let refSnapshot = NiriStateZigKernel.makeSnapshot(columns: refEngine.columns(in: wsId))

            let zig = NiriStateZigKernel.resolveMutation(snapshot: zigSnapshot, request: request)
            let reference = NiriReferenceWindowOps.resolve(snapshot: refSnapshot, request: request)
            assertMutationOutcomeParity(zig: zig, reference: reference)

            let zigApplied = applyMutationOutcome(
                engine: zigEngine,
                workspaceId: wsId,
                state: &zigState,
                snapshot: zigSnapshot,
                outcome: zig,
                workingFrame: dual.workingFrame,
                gaps: dual.gaps
            )
            let refApplied = applyMutationOutcome(
                engine: refEngine,
                workspaceId: wsId,
                state: &refState,
                snapshot: refSnapshot,
                outcome: reference,
                workingFrame: dual.workingFrame,
                gaps: dual.gaps
            )
            #expect(zigApplied == refApplied)

            assertMutationInvariants(engine: zigEngine, workspaceId: wsId)
            assertMutationInvariants(engine: refEngine, workspaceId: wsId)
            #expect(layoutSignature(engine: zigEngine, workspaceId: wsId) == layoutSignature(engine: refEngine, workspaceId: wsId))
        }
    }

    @Test func randomizedMutationTraceParityMatchesReferenceModel() {
        let traceCount = 5_000
        let opsPerTrace = 12
        var rng = MutationLCG(seed: 0x1234_ABCD_5678_EF01)

        for trace in 0 ..< traceCount {
            let dual = makeDualEngines(seed: UInt64(20_000 + trace))
            let zigEngine = dual.zigEngine
            let refEngine = dual.referenceEngine
            let wsId = dual.workspaceId
            var zigState = ViewportState()
            var refState = ViewportState()

            for _ in 0 ..< opsPerTrace {
                let zigSnapshot = NiriStateZigKernel.makeSnapshot(columns: zigEngine.columns(in: wsId))
                let refSnapshot = NiriStateZigKernel.makeSnapshot(columns: refEngine.columns(in: wsId))
                #expect(zigSnapshot.windowEntries.count == refSnapshot.windowEntries.count)
                #expect(!zigSnapshot.windowEntries.isEmpty)
                guard !zigSnapshot.windowEntries.isEmpty else { break }

                let request = makeRandomMutationRequest(
                    snapshot: zigSnapshot,
                    maxWindowsPerColumn: zigEngine.maxWindowsPerColumn,
                    infiniteLoop: zigEngine.infiniteLoop,
                    rng: &rng
                )

                let zig = NiriStateZigKernel.resolveMutation(snapshot: zigSnapshot, request: request)
                let reference = NiriReferenceWindowOps.resolve(snapshot: refSnapshot, request: request)
                assertMutationOutcomeParity(zig: zig, reference: reference)

                let zigApplied = applyMutationOutcome(
                    engine: zigEngine,
                    workspaceId: wsId,
                    state: &zigState,
                    snapshot: zigSnapshot,
                    outcome: zig,
                    workingFrame: dual.workingFrame,
                    gaps: dual.gaps
                )
                let refApplied = applyMutationOutcome(
                    engine: refEngine,
                    workspaceId: wsId,
                    state: &refState,
                    snapshot: refSnapshot,
                    outcome: reference,
                    workingFrame: dual.workingFrame,
                    gaps: dual.gaps
                )
                #expect(zigApplied == refApplied)

                if zig.hasTarget {
                    #expect(zig.targetWindowIndex != nil)
                }

                assertMutationInvariants(engine: zigEngine, workspaceId: wsId)
                assertMutationInvariants(engine: refEngine, workspaceId: wsId)
                #expect(layoutSignature(engine: zigEngine, workspaceId: wsId) == layoutSignature(engine: refEngine, workspaceId: wsId))
            }
        }
    }

    @Test func windowOpsMutationPlannerBenchmarkHarnessP95() throws {
        let dual = makeDualEngines(seed: 0xD00D_BEEF_F00D_1234)
        let snapshot = NiriStateZigKernel.makeSnapshot(columns: dual.zigEngine.columns(in: dual.workspaceId))
        #expect(!snapshot.windowEntries.isEmpty)
        guard !snapshot.windowEntries.isEmpty else { return }

        var rng = MutationLCG(seed: 0xABCDEF0123456789)
        var requests: [NiriStateZigKernel.MutationRequest] = []
        requests.reserveCapacity(10_000)
        for _ in 0 ..< 10_000 {
            requests.append(
                makeRandomMutationRequest(
                    snapshot: snapshot,
                    maxWindowsPerColumn: dual.zigEngine.maxWindowsPerColumn,
                    infiniteLoop: dual.zigEngine.infiniteLoop,
                    rng: &rng
                )
            )
        }

        var samples: [Double] = []
        samples.reserveCapacity(requests.count)

        for request in requests {
            let t0 = CACurrentMediaTime()
            _ = NiriStateZigKernel.resolveMutation(snapshot: snapshot, request: request)
            samples.append(CACurrentMediaTime() - t0)
        }

        let p95 = percentile(samples, 0.95)
        print(String(format: "Niri window-ops mutation planner p95 (zig): %.9f", p95))

        let baseline = try BenchmarkBaselines.loadPhase3WindowOps()
        let perfLimit = baseline.window_ops_p95_sec * 1.10

        #expect(p95 > 0)
        #expect(p95 <= perfLimit)
    }
}
