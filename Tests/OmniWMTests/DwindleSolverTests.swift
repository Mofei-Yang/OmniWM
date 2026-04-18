import CoreGraphics
import Foundation
import Testing

@testable import OmniWM

/// Exercises the pure-Swift Dwindle solver with the same scenarios that used
/// to live in `Zig/omniwm_kernels/src/dwindle_layout.zig`'s test block,
/// ensuring the Swift port preserves the gap, aspect-ratio, and subtree-min
/// behaviors. Engine-level integration tests stay in
/// `DwindleLayoutEngineTests.swift`.
@Suite struct DwindleSolverTests {
    private func baseInput() -> DwindleSolveInput {
        DwindleSolveInput(
            rootIndex: 0,
            screen: CGRect(x: 0, y: 0, width: 1600, height: 1000),
            innerGap: 8,
            outerGapTop: 0,
            outerGapBottom: 0,
            outerGapLeft: 0,
            outerGapRight: 0,
            singleWindowAspectWidth: 4,
            singleWindowAspectHeight: 3,
            singleWindowAspectTolerance: 0.1,
            minimumDimension: 1,
            gapSticksTolerance: 2,
            splitRatioMin: 0.1,
            splitRatioMax: 1.9,
            splitFractionDivisor: 2,
            splitFractionMin: 0.05,
            splitFractionMax: 0.95
        )
    }

    private func leaf(
        minWidth: CGFloat = 1,
        minHeight: CGFloat = 1,
        hasWindow: Bool = true,
        fullscreen: Bool = false
    ) -> DwindleSolveNode {
        DwindleSolveNode(
            firstChildIndex: -1,
            secondChildIndex: -1,
            splitRatio: 1.0,
            minWidth: minWidth,
            minHeight: minHeight,
            kind: .leaf,
            orientation: .horizontal,
            hasWindow: hasWindow,
            fullscreen: fullscreen
        )
    }

    private func split(
        firstChildIndex: Int,
        secondChildIndex: Int,
        orientation: DwindleOrientation = .horizontal,
        splitRatio: CGFloat = 1.0
    ) -> DwindleSolveNode {
        DwindleSolveNode(
            firstChildIndex: firstChildIndex,
            secondChildIndex: secondChildIndex,
            splitRatio: splitRatio,
            minWidth: 0,
            minHeight: 0,
            kind: .split,
            orientation: orientation,
            hasWindow: false,
            fullscreen: false
        )
    }

    private func expectFrame(
        _ actual: CGRect?,
        _ expected: CGRect,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard let actual else {
            Issue.record("expected frame \(expected) but got nil", sourceLocation: sourceLocation)
            return
        }
        let tolerance: CGFloat = 0.001
        #expect(abs(actual.minX - expected.minX) < tolerance, sourceLocation: sourceLocation)
        #expect(abs(actual.minY - expected.minY) < tolerance, sourceLocation: sourceLocation)
        #expect(abs(actual.width - expected.width) < tolerance, sourceLocation: sourceLocation)
        #expect(abs(actual.height - expected.height) < tolerance, sourceLocation: sourceLocation)
    }

    @Test func appliesOuterGapsBeforeSingleWindowAspectMath() throws {
        var input = baseInput()
        input.outerGapTop = 50
        input.outerGapBottom = 50
        input.outerGapLeft = 100
        input.outerGapRight = 100

        let outputs = try solveDwindleLayout(input, nodes: [leaf()])
        expectFrame(outputs[0], CGRect(x: 200, y: 50, width: 1200, height: 900))
    }

    @Test func treatsZeroAspectRatioAsFillMode() throws {
        var input = baseInput()
        input.singleWindowAspectWidth = 0
        input.singleWindowAspectHeight = 0
        input.outerGapLeft = 20
        input.outerGapRight = 40
        input.outerGapTop = 10
        input.outerGapBottom = 30

        let outputs = try solveDwindleLayout(input, nodes: [leaf()])
        expectFrame(outputs[0], CGRect(x: 20, y: 30, width: 1540, height: 960))
    }

    @Test func keepsSingleFullscreenWindowsOnFullScreenRect() throws {
        var input = baseInput()
        input.screen = CGRect(x: 10, y: 20, width: 1280, height: 720)
        input.outerGapLeft = 50
        input.outerGapRight = 60

        let outputs = try solveDwindleLayout(input, nodes: [leaf(fullscreen: true)])
        expectFrame(outputs[0], CGRect(x: 10, y: 20, width: 1280, height: 720))
    }

    @Test func givesFullscreenLeavesTheFullTilingAreaInMultiWindowLayouts() throws {
        var input = baseInput()
        input.screen = CGRect(x: 0, y: 0, width: 1000, height: 500)
        input.innerGap = 10
        input.outerGapTop = 10
        input.outerGapBottom = 20
        input.outerGapLeft = 30
        input.outerGapRight = 40

        let nodes: [DwindleSolveNode] = [
            split(firstChildIndex: 1, secondChildIndex: 2),
            leaf(),
            leaf(fullscreen: true),
        ]

        let outputs = try solveDwindleLayout(input, nodes: nodes)
        expectFrame(outputs[0], CGRect(x: 30, y: 20, width: 930, height: 470))
        expectFrame(outputs[1], CGRect(x: 60, y: 40, width: 430, height: 440))
        expectFrame(outputs[2], CGRect(x: 30, y: 20, width: 930, height: 470))
    }

    @Test func appliesInnerGapsAndWritesSplitFrames() throws {
        var input = baseInput()
        input.screen = CGRect(x: 0, y: 0, width: 1000, height: 500)
        input.innerGap = 10

        let nodes: [DwindleSolveNode] = [
            split(firstChildIndex: 1, secondChildIndex: 2),
            leaf(),
            leaf(),
        ]

        let outputs = try solveDwindleLayout(input, nodes: nodes)
        expectFrame(outputs[0], CGRect(x: 0, y: 0, width: 1000, height: 500))
        expectFrame(outputs[1], CGRect(x: 0, y: 0, width: 495, height: 500))
        expectFrame(outputs[2], CGRect(x: 505, y: 0, width: 495, height: 500))
    }

    @Test func clampsSplitRatiosUsingAggregatedSubtreeMinima() throws {
        var input = baseInput()
        input.screen = CGRect(x: 0, y: 0, width: 700, height: 800)
        input.innerGap = 0

        let nodes: [DwindleSolveNode] = [
            split(firstChildIndex: 1, secondChildIndex: 4, splitRatio: 0.3),
            split(firstChildIndex: 2, secondChildIndex: 3, orientation: .vertical),
            leaf(minWidth: 300, minHeight: 200),
            leaf(minWidth: 100, minHeight: 400),
            leaf(minWidth: 200, minHeight: 100),
        ]

        let outputs = try solveDwindleLayout(input, nodes: nodes)
        expectFrame(outputs[1], CGRect(x: 0, y: 0, width: 300, height: 800))
        expectFrame(outputs[2], CGRect(x: 0, y: 0, width: 300, height: 400))
        expectFrame(outputs[3], CGRect(x: 0, y: 400, width: 300, height: 400))
        expectFrame(outputs[4], CGRect(x: 300, y: 0, width: 400, height: 800))
    }

    @Test func fallsBackForPlaceholderLeavesAndMissingChildren() throws {
        var input = baseInput()
        input.screen = CGRect(x: 0, y: 0, width: 400, height: 200)
        input.innerGap = 0

        let placeholderNodes: [DwindleSolveNode] = [
            split(firstChildIndex: 1, secondChildIndex: 2, orientation: .vertical),
            leaf(hasWindow: false),
            split(firstChildIndex: 3, secondChildIndex: 4),
            leaf(minWidth: 100, minHeight: 400),
            leaf(minWidth: 100, minHeight: 400),
        ]

        let placeholderOutputs = try solveDwindleLayout(input, nodes: placeholderNodes)
        #expect(placeholderOutputs[1] == nil)
        expectFrame(
            placeholderOutputs[2],
            CGRect(x: 0, y: 200.0 / 401.0, width: 400, height: 200.0 * (400.0 / 401.0))
        )

        var missingInput = input
        missingInput.screen = CGRect(x: 0, y: 0, width: 600, height: 300)

        let missingNodes: [DwindleSolveNode] = [
            split(firstChildIndex: 1, secondChildIndex: -1, orientation: .vertical),
            split(firstChildIndex: 2, secondChildIndex: 3),
            leaf(minWidth: 100, minHeight: 500),
            leaf(minWidth: 100, minHeight: 500),
        ]

        let missingOutputs = try solveDwindleLayout(missingInput, nodes: missingNodes)
        expectFrame(
            missingOutputs[1],
            CGRect(x: 0, y: 0, width: 600, height: 300.0 * (500.0 / 501.0))
        )
    }
}
