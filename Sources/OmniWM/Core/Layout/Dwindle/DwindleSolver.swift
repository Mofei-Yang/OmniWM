import CoreGraphics
import Foundation

/// Pure Swift port of the previous `dwindle_layout.zig` kernel.
///
/// The solver walks a flat array of binary-tree nodes (each either a split or
/// a leaf) and computes the frame for every node that carries a window. The
/// algorithm is self-contained — no state, no I/O — so failures are represented
/// as thrown `DwindleSolverError` values rather than a status enum.
///
/// The entry point matches the former Zig ABI semantics:
/// - An empty `nodes` array is a no-op.
/// - The returned array aligns 1:1 with `nodes`; `nil` entries correspond to
///   nodes that intentionally produce no frame (e.g. placeholder leaves with
///   `hasWindow == false`).
/// - Precondition violations (out-of-range child indices, unknown orientations,
///   cycles) throw `DwindleSolverError.invalidArgument`, mirroring the old
///   `OMNIWM_KERNELS_STATUS_INVALID_ARGUMENT` return code.
enum DwindleSolverError: Error, Equatable {
    case invalidArgument
}

struct DwindleSolveInput: Equatable {
    var rootIndex: Int
    var screen: CGRect
    var innerGap: CGFloat
    var outerGapTop: CGFloat
    var outerGapBottom: CGFloat
    var outerGapLeft: CGFloat
    var outerGapRight: CGFloat
    var singleWindowAspectWidth: CGFloat
    var singleWindowAspectHeight: CGFloat
    var singleWindowAspectTolerance: CGFloat
    var minimumDimension: CGFloat
    var gapSticksTolerance: CGFloat
    var splitRatioMin: CGFloat
    var splitRatioMax: CGFloat
    var splitFractionDivisor: CGFloat
    var splitFractionMin: CGFloat
    var splitFractionMax: CGFloat
}

struct DwindleSolveNode: Equatable {
    enum Kind: Equatable {
        case split
        case leaf
    }

    var firstChildIndex: Int       // -1 == none
    var secondChildIndex: Int      // -1 == none
    var splitRatio: CGFloat
    var minWidth: CGFloat
    var minHeight: CGFloat
    var kind: Kind
    var orientation: DwindleOrientation
    var hasWindow: Bool
    var fullscreen: Bool
}

/// Returns per-node frames, aligned 1:1 with `nodes`. `nil` entries mark nodes
/// that produce no frame (placeholder leaves, empty trees). Throws
/// `DwindleSolverError.invalidArgument` on malformed input (out-of-range child
/// indices, cycles, etc.).
func solveDwindleLayout(
    _ input: DwindleSolveInput,
    nodes: [DwindleSolveNode]
) throws -> [CGRect?] {
    if nodes.isEmpty {
        return []
    }

    var outputs = [CGRect?](repeating: nil, count: nodes.count)
    var minCache = [CGSize](repeating: .zero, count: nodes.count)
    var visitStates = [VisitState](repeating: .unvisited, count: nodes.count)

    guard let rootIndex = try parseChildIndex(input.rootIndex, nodeCount: nodes.count) else {
        throw DwindleSolverError.invalidArgument
    }

    let windowCount = try countWindows(nodes)
    if windowCount == 0 {
        return outputs
    }

    if windowCount == 1 {
        try solveSingleWindow(
            rootIndex: rootIndex,
            nodes: nodes,
            input: input,
            outputs: &outputs
        )
        return outputs
    }

    let tilingArea = applyOuterGapsOnly(rect: input.screen, input: input)
    try solveNode(
        index: rootIndex,
        rect: tilingArea,
        tilingArea: tilingArea,
        nodes: nodes,
        input: input,
        minCache: &minCache,
        visitStates: &visitStates,
        outputs: &outputs
    )
    return outputs
}

// MARK: - Private solver implementation

private enum VisitState {
    case unvisited
    case visiting
    case done
}

private func swiftMax(_ lhs: CGFloat, _ rhs: CGFloat) -> CGFloat {
    rhs > lhs ? rhs : lhs
}

private func swiftMin(_ lhs: CGFloat, _ rhs: CGFloat) -> CGFloat {
    rhs < lhs ? rhs : lhs
}

private func sanitizeMinimum(_ value: CGFloat) -> CGFloat {
    if !value.isFinite || value <= 0 {
        return 1
    }
    return value
}

private func fallbackSize(input: DwindleSolveInput) -> CGSize {
    let minimum = sanitizeMinimum(input.minimumDimension)
    return CGSize(width: minimum, height: minimum)
}

private func sanitizeLeafDimension(_ value: CGFloat, input: DwindleSolveInput) -> CGFloat {
    let minimum = sanitizeMinimum(input.minimumDimension)
    if !value.isFinite || value < minimum {
        return minimum
    }
    return value
}

private func applyOuterGapsOnly(rect: CGRect, input: DwindleSolveInput) -> CGRect {
    let minimum = sanitizeMinimum(input.minimumDimension)
    return CGRect(
        x: rect.minX + input.outerGapLeft,
        y: rect.minY + input.outerGapBottom,
        width: swiftMax(minimum, rect.width - input.outerGapLeft - input.outerGapRight),
        height: swiftMax(minimum, rect.height - input.outerGapTop - input.outerGapBottom)
    )
}

private func applyGaps(rect: CGRect, tilingArea: CGRect, input: DwindleSolveInput) -> CGRect {
    let tolerance = input.gapSticksTolerance
    let minimum = sanitizeMinimum(input.minimumDimension)
    let atLeft = abs(rect.minX - tilingArea.minX) < tolerance
    let atRight = abs(rect.maxX - tilingArea.maxX) < tolerance
    let atBottom = abs(rect.minY - tilingArea.minY) < tolerance
    let atTop = abs(rect.maxY - tilingArea.maxY) < tolerance

    let halfInnerGap = input.innerGap / 2
    let leftGap = atLeft ? input.outerGapLeft : halfInnerGap
    let rightGap = atRight ? input.outerGapRight : halfInnerGap
    let bottomGap = atBottom ? input.outerGapBottom : halfInnerGap
    let topGap = atTop ? input.outerGapTop : halfInnerGap

    return CGRect(
        x: rect.minX + leftGap,
        y: rect.minY + bottomGap,
        width: swiftMax(minimum, rect.width - leftGap - rightGap),
        height: swiftMax(minimum, rect.height - topGap - bottomGap)
    )
}

private func validAspectRatio(width: CGFloat, height: CGFloat) -> CGFloat? {
    guard width.isFinite, height.isFinite, width > 0, height > 0 else {
        return nil
    }
    let ratio = width / height
    guard ratio.isFinite, ratio > 0 else {
        return nil
    }
    return ratio
}

private func singleWindowRect(rect: CGRect, input: DwindleSolveInput) -> CGRect {
    guard let targetRatio = validAspectRatio(
        width: input.singleWindowAspectWidth,
        height: input.singleWindowAspectHeight
    ) else {
        return rect
    }
    guard let currentRatio = validAspectRatio(width: rect.width, height: rect.height) else {
        return rect
    }

    if abs(targetRatio - currentRatio) < input.singleWindowAspectTolerance {
        return rect
    }

    var width = rect.width
    var height = rect.height
    if currentRatio > targetRatio {
        width = height * targetRatio
    } else {
        height = width / targetRatio
    }

    return CGRect(
        x: rect.minX + (rect.width - width) / 2,
        y: rect.minY + (rect.height - height) / 2,
        width: width,
        height: height
    )
}

private func ratioToFraction(_ ratio: CGFloat, input: DwindleSolveInput) -> CGFloat {
    let safeDivisor: CGFloat
    if input.splitFractionDivisor.isFinite, input.splitFractionDivisor > 0 {
        safeDivisor = input.splitFractionDivisor
    } else {
        safeDivisor = 2
    }

    var clampedRatio = ratio.isFinite ? ratio : 1
    clampedRatio = swiftMax(input.splitRatioMin, swiftMin(input.splitRatioMax, clampedRatio))
    let fraction = clampedRatio / safeDivisor
    return swiftMax(input.splitFractionMin, swiftMin(input.splitFractionMax, fraction))
}

private func parseChildIndex(_ rawIndex: Int, nodeCount: Int) throws -> Int? {
    if rawIndex == -1 {
        return nil
    }
    if rawIndex < -1 {
        throw DwindleSolverError.invalidArgument
    }
    if rawIndex >= nodeCount {
        throw DwindleSolverError.invalidArgument
    }
    return rawIndex
}

private func leafMinSize(_ node: DwindleSolveNode, input: DwindleSolveInput) -> CGSize {
    CGSize(
        width: sanitizeLeafDimension(node.minWidth, input: input),
        height: sanitizeLeafDimension(node.minHeight, input: input)
    )
}

private func computeSubtreeMinSize(
    index: Int,
    nodes: [DwindleSolveNode],
    input: DwindleSolveInput,
    minCache: inout [CGSize],
    visitStates: inout [VisitState]
) throws -> CGSize {
    switch visitStates[index] {
    case .done:
        return minCache[index]
    case .visiting:
        throw DwindleSolverError.invalidArgument
    case .unvisited:
        break
    }

    visitStates[index] = .visiting
    let node = nodes[index]

    let result: CGSize
    switch node.kind {
    case .leaf:
        result = leafMinSize(node, input: input)
    case .split:
        let firstIndex = try parseChildIndex(node.firstChildIndex, nodeCount: nodes.count)
        let secondIndex = try parseChildIndex(node.secondChildIndex, nodeCount: nodes.count)

        let firstMin: CGSize
        if let firstIndex {
            firstMin = try computeSubtreeMinSize(
                index: firstIndex,
                nodes: nodes,
                input: input,
                minCache: &minCache,
                visitStates: &visitStates
            )
        } else {
            firstMin = fallbackSize(input: input)
        }

        let secondMin: CGSize
        if let secondIndex {
            secondMin = try computeSubtreeMinSize(
                index: secondIndex,
                nodes: nodes,
                input: input,
                minCache: &minCache,
                visitStates: &visitStates
            )
        } else {
            secondMin = fallbackSize(input: input)
        }

        switch node.orientation {
        case .horizontal:
            result = CGSize(
                width: firstMin.width + secondMin.width,
                height: swiftMax(firstMin.height, secondMin.height)
            )
        case .vertical:
            result = CGSize(
                width: swiftMax(firstMin.width, secondMin.width),
                height: firstMin.height + secondMin.height
            )
        }
    }

    minCache[index] = result
    visitStates[index] = .done
    return result
}

private struct SplitRects {
    var first: CGRect
    var second: CGRect
}

private func splitRect(
    rect: CGRect,
    orientation: DwindleOrientation,
    ratio: CGFloat,
    firstMin: CGSize,
    secondMin: CGSize,
    input: DwindleSolveInput
) -> SplitRects {
    let minimum = sanitizeMinimum(input.minimumDimension)
    var fraction = ratioToFraction(ratio, input: input)

    switch orientation {
    case .horizontal:
        let totalMin = firstMin.width + secondMin.width
        if totalMin > rect.width {
            fraction = firstMin.width / swiftMax(totalMin, minimum)
        } else {
            let minFraction = firstMin.width / rect.width
            let maxFraction = (rect.width - secondMin.width) / rect.width
            fraction = swiftMax(minFraction, swiftMin(maxFraction, fraction))
        }

        let firstWidth = rect.width * fraction
        let secondWidth = rect.width - firstWidth
        return SplitRects(
            first: CGRect(
                x: rect.minX,
                y: rect.minY,
                width: firstWidth,
                height: rect.height
            ),
            second: CGRect(
                x: rect.minX + firstWidth,
                y: rect.minY,
                width: secondWidth,
                height: rect.height
            )
        )

    case .vertical:
        let totalMin = firstMin.height + secondMin.height
        if totalMin > rect.height {
            fraction = firstMin.height / swiftMax(totalMin, minimum)
        } else {
            let minFraction = firstMin.height / rect.height
            let maxFraction = (rect.height - secondMin.height) / rect.height
            fraction = swiftMax(minFraction, swiftMin(maxFraction, fraction))
        }

        let firstHeight = rect.height * fraction
        let secondHeight = rect.height - firstHeight
        return SplitRects(
            first: CGRect(
                x: rect.minX,
                y: rect.minY,
                width: rect.width,
                height: firstHeight
            ),
            second: CGRect(
                x: rect.minX,
                y: rect.minY + firstHeight,
                width: rect.width,
                height: secondHeight
            )
        )
    }
}

private func solveNode(
    index: Int,
    rect: CGRect,
    tilingArea: CGRect,
    nodes: [DwindleSolveNode],
    input: DwindleSolveInput,
    minCache: inout [CGSize],
    visitStates: inout [VisitState],
    outputs: inout [CGRect?]
) throws {
    let node = nodes[index]

    switch node.kind {
    case .leaf:
        if !node.hasWindow {
            return
        }

        let target: CGRect = if node.fullscreen {
            tilingArea
        } else {
            applyGaps(rect: rect, tilingArea: tilingArea, input: input)
        }
        outputs[index] = target

    case .split:
        outputs[index] = rect

        let firstIndex = try parseChildIndex(node.firstChildIndex, nodeCount: nodes.count)
        let secondIndex = try parseChildIndex(node.secondChildIndex, nodeCount: nodes.count)

        let firstMin: CGSize
        if let firstIndex {
            firstMin = try computeSubtreeMinSize(
                index: firstIndex,
                nodes: nodes,
                input: input,
                minCache: &minCache,
                visitStates: &visitStates
            )
        } else {
            firstMin = fallbackSize(input: input)
        }

        let secondMin: CGSize
        if let secondIndex {
            secondMin = try computeSubtreeMinSize(
                index: secondIndex,
                nodes: nodes,
                input: input,
                minCache: &minCache,
                visitStates: &visitStates
            )
        } else {
            secondMin = fallbackSize(input: input)
        }

        let splits = splitRect(
            rect: rect,
            orientation: node.orientation,
            ratio: node.splitRatio,
            firstMin: firstMin,
            secondMin: secondMin,
            input: input
        )

        if let firstIndex {
            try solveNode(
                index: firstIndex,
                rect: splits.first,
                tilingArea: tilingArea,
                nodes: nodes,
                input: input,
                minCache: &minCache,
                visitStates: &visitStates,
                outputs: &outputs
            )
        }
        if let secondIndex {
            try solveNode(
                index: secondIndex,
                rect: splits.second,
                tilingArea: tilingArea,
                nodes: nodes,
                input: input,
                minCache: &minCache,
                visitStates: &visitStates,
                outputs: &outputs
            )
        }
    }
}

private func solveSingleWindow(
    rootIndex: Int,
    nodes: [DwindleSolveNode],
    input: DwindleSolveInput,
    outputs: inout [CGRect?]
) throws {
    var currentIndex = rootIndex
    var steps = 0

    while steps < nodes.count {
        let node = nodes[currentIndex]
        if node.kind != .split {
            break
        }

        guard let firstIndex = try parseChildIndex(node.firstChildIndex, nodeCount: nodes.count) else {
            break
        }
        currentIndex = firstIndex
        steps += 1
    }

    if steps == nodes.count, nodes[currentIndex].kind == .split {
        throw DwindleSolverError.invalidArgument
    }

    let node = nodes[currentIndex]
    guard node.kind == .leaf, node.hasWindow else {
        return
    }

    let tilingArea = applyOuterGapsOnly(rect: input.screen, input: input)
    let rect: CGRect = if node.fullscreen {
        input.screen
    } else {
        singleWindowRect(rect: tilingArea, input: input)
    }
    outputs[currentIndex] = rect
}

private func countWindows(_ nodes: [DwindleSolveNode]) throws -> Int {
    var count = 0
    for node in nodes {
        switch node.kind {
        case .leaf:
            if node.hasWindow {
                count += 1
            }
        case .split:
            break
        }
    }
    return count
}
