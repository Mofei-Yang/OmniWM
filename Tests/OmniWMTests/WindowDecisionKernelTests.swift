import AppKit
import Foundation
import Testing

@testable import OmniWM

private func makeFacts(
    subrole: String? = kAXStandardWindowSubrole as String,
    title: String? = "Title",
    hasCloseButton: Bool = true,
    hasFullscreenButton: Bool = true,
    fullscreenButtonEnabled: Bool? = true,
    hasZoomButton: Bool = true,
    hasMinimizeButton: Bool = true,
    appPolicy: NSApplication.ActivationPolicy? = .regular,
    attributeFetchSucceeded: Bool = true
) -> AXWindowFacts {
    AXWindowFacts(
        role: kAXWindowRole as String,
        subrole: subrole,
        title: title,
        hasCloseButton: hasCloseButton,
        hasFullscreenButton: hasFullscreenButton,
        fullscreenButtonEnabled: fullscreenButtonEnabled,
        hasZoomButton: hasZoomButton,
        hasMinimizeButton: hasMinimizeButton,
        appPolicy: appPolicy,
        bundleId: nil,
        attributeFetchSucceeded: attributeFetchSucceeded
    )
}

/// Exercises the pure-Swift window-decision kernel. Previously this suite
/// validated the `omniwm_window_decision_solve` Zig ABI; after porting the
/// algorithm into Swift the tests target the native function directly with
/// the same input/expected-output scenarios.
@Suite struct WindowDecisionKernelTests {
    @Test func defaultFactsWithZeroAttributeFetchProducesDeferredUndecided() {
        let output = solveWindowDecisionKernel(
            matchedUserAction: nil,
            matchedBuiltInAction: nil,
            matchedBuiltInSourceKind: nil,
            specialCaseKind: .none,
            facts: makeFacts(attributeFetchSucceeded: false),
            titleRequired: false,
            appFullscreen: false
        )

        #expect(output.disposition == .undecided)
        #expect(output.sourceKind == .heuristic)
        #expect(output.builtInSourceKind == nil)
        #expect(output.layoutDecisionKind == .fallbackLayout)
        #expect(output.deferredReason == .attributeFetchFailed)
        #expect(output.heuristicReasons == [.attributeFetchFailed])
    }

    @Test func standardManagedFallbackDecodesToHeuristicManaged() {
        let output = solveWindowDecisionKernel(
            matchedUserAction: nil,
            matchedBuiltInAction: nil,
            matchedBuiltInSourceKind: nil,
            specialCaseKind: .none,
            facts: makeFacts(),
            titleRequired: false,
            appFullscreen: false
        )

        #expect(output.disposition == .managed)
        #expect(output.sourceKind == .heuristic)
        #expect(output.builtInSourceKind == nil)
        #expect(output.layoutDecisionKind == .fallbackLayout)
        #expect(output.deferredReason == nil)
        #expect(output.heuristicReasons.isEmpty)
    }

    @Test func explicitUserRuleReturnsExplicitUserSource() {
        let output = solveWindowDecisionKernel(
            matchedUserAction: .tile,
            matchedBuiltInAction: nil,
            matchedBuiltInSourceKind: nil,
            specialCaseKind: .none,
            facts: makeFacts(),
            titleRequired: false,
            appFullscreen: false
        )

        #expect(output.disposition == .managed)
        #expect(output.sourceKind == .userRule)
        #expect(output.builtInSourceKind == nil)
        #expect(output.layoutDecisionKind == .explicitLayout)
        #expect(output.deferredReason == nil)
    }

    @Test func explicitBuiltInRuleReturnsStableBuiltInSourceKind() {
        let output = solveWindowDecisionKernel(
            matchedUserAction: nil,
            matchedBuiltInAction: .float,
            matchedBuiltInSourceKind: .defaultFloatingApp,
            specialCaseKind: .none,
            facts: makeFacts(),
            titleRequired: false,
            appFullscreen: false
        )

        #expect(output.disposition == .floating)
        #expect(output.sourceKind == .builtInRule)
        #expect(output.builtInSourceKind == .defaultFloatingApp)
        #expect(output.layoutDecisionKind == .explicitLayout)
    }

    @Test func titleDeferralCanReturnBuiltInFallbackSource() {
        let output = solveWindowDecisionKernel(
            matchedUserAction: nil,
            matchedBuiltInAction: .auto,
            matchedBuiltInSourceKind: .browserPictureInPicture,
            specialCaseKind: .none,
            facts: makeFacts(title: nil),
            titleRequired: true,
            appFullscreen: false
        )

        #expect(output.disposition == .undecided)
        #expect(output.sourceKind == .builtInRule)
        #expect(output.builtInSourceKind == .browserPictureInPicture)
        #expect(output.deferredReason == .requiredTitleMissing)
    }

    @Test func heuristicReasonIsStableForMissingFullscreenButton() {
        let output = solveWindowDecisionKernel(
            matchedUserAction: nil,
            matchedBuiltInAction: nil,
            matchedBuiltInSourceKind: nil,
            specialCaseKind: .none,
            facts: makeFacts(
                hasFullscreenButton: false,
                fullscreenButtonEnabled: nil
            ),
            titleRequired: false,
            appFullscreen: false
        )

        #expect(output.disposition == .floating)
        #expect(output.heuristicReasons == [.missingFullscreenButton])
    }

    @Test func explicitUserRuleBeatsBuiltInAndSpecialCase() {
        let output = solveWindowDecisionKernel(
            matchedUserAction: .tile,
            matchedBuiltInAction: .float,
            matchedBuiltInSourceKind: .defaultFloatingApp,
            specialCaseKind: .cleanShotRecordingOverlay,
            facts: makeFacts(),
            titleRequired: true,
            appFullscreen: true
        )

        #expect(output.disposition == .managed)
        #expect(output.sourceKind == .userRule)
        #expect(output.layoutDecisionKind == .explicitLayout)
    }

    @Test func explicitBuiltInRuleWinsBeforeFullscreenFallback() {
        let output = solveWindowDecisionKernel(
            matchedUserAction: nil,
            matchedBuiltInAction: .float,
            matchedBuiltInSourceKind: .defaultFloatingApp,
            specialCaseKind: .none,
            facts: makeFacts(),
            titleRequired: false,
            appFullscreen: true
        )

        #expect(output.disposition == .floating)
        #expect(output.sourceKind == .builtInRule)
        #expect(output.builtInSourceKind == .defaultFloatingApp)
        #expect(output.layoutDecisionKind == .explicitLayout)
    }

    @Test func specialCaseWinsBeforeTitleDeferral() {
        let output = solveWindowDecisionKernel(
            matchedUserAction: nil,
            matchedBuiltInAction: nil,
            matchedBuiltInSourceKind: nil,
            specialCaseKind: .cleanShotRecordingOverlay,
            facts: makeFacts(title: nil),
            titleRequired: true,
            appFullscreen: false
        )

        #expect(output.disposition == .floating)
        #expect(output.sourceKind == .builtInRule)
        #expect(output.builtInSourceKind == .cleanShotRecordingOverlay)
        #expect(output.layoutDecisionKind == .explicitLayout)
    }

    @Test func titleDeferralKeepsFallbackSourceAndNoHeuristicReasons() {
        let output = solveWindowDecisionKernel(
            matchedUserAction: .auto,
            matchedBuiltInAction: nil,
            matchedBuiltInSourceKind: nil,
            specialCaseKind: .none,
            facts: makeFacts(title: nil),
            titleRequired: true,
            appFullscreen: false
        )

        #expect(output.disposition == .undecided)
        #expect(output.sourceKind == .userRule)
        #expect(output.layoutDecisionKind == .fallbackLayout)
        #expect(output.deferredReason == .requiredTitleMissing)
        #expect(output.heuristicReasons.isEmpty)
    }

    @Test func degradedAxKeepsExplicitFloatUserRule() {
        let output = solveWindowDecisionKernel(
            matchedUserAction: .float,
            matchedBuiltInAction: nil,
            matchedBuiltInSourceKind: nil,
            specialCaseKind: .none,
            facts: makeFacts(attributeFetchSucceeded: false),
            titleRequired: false,
            appFullscreen: false
        )

        #expect(output.disposition == .floating)
        #expect(output.sourceKind == .userRule)
        #expect(output.layoutDecisionKind == .explicitLayout)
        #expect(output.deferredReason == nil)
        #expect(output.heuristicReasons.isEmpty)
    }

    @Test func heuristicFallbackUsesAccessoryFloatingClassification() {
        let output = solveWindowDecisionKernel(
            matchedUserAction: nil,
            matchedBuiltInAction: nil,
            matchedBuiltInSourceKind: nil,
            specialCaseKind: .none,
            facts: makeFacts(
                hasCloseButton: false,
                appPolicy: .accessory
            ),
            titleRequired: false,
            appFullscreen: false
        )

        #expect(output.disposition == .floating)
        #expect(output.sourceKind == .heuristic)
        #expect(output.layoutDecisionKind == .fallbackLayout)
        #expect(output.heuristicReasons == [.accessoryWithoutClose])
    }
}
