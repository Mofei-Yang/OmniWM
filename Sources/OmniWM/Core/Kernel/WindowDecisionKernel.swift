import AppKit
import Foundation

enum WindowDecisionBuiltInSourceKind: Equatable {
    case defaultFloatingApp
    case browserPictureInPicture
    case cleanShotRecordingOverlay
}

enum WindowDecisionSpecialCaseKind: Equatable {
    case none
    case cleanShotRecordingOverlay
}

enum WindowDecisionKernelSourceKind: Equatable {
    case userRule
    case builtInRule
    case heuristic
}

struct WindowDecisionKernelOutput: Equatable {
    let disposition: WindowDecisionDisposition
    let sourceKind: WindowDecisionKernelSourceKind
    let builtInSourceKind: WindowDecisionBuiltInSourceKind?
    let layoutDecisionKind: WindowDecisionLayoutKind
    let deferredReason: WindowDecisionDeferredReason?
    let heuristicReasons: [AXWindowHeuristicReason]

    var heuristicDisposition: AXWindowHeuristicDisposition {
        AXWindowHeuristicDisposition(
            disposition: disposition,
            reasons: heuristicReasons
        )
    }
}

/// Native Swift port of the previous `window_decision.zig` kernel.
///
/// Pure data-in/data-out — no state, no I/O, no FFI — so the algorithm is
/// infallible and returns its output directly. Precedence (highest first):
/// 1. Explicit `tile`/`float` user rule.
/// 2. Explicit `tile`/`float` built-in rule.
/// 3. CleanShot recording overlay special case.
/// 4. Required title missing (defer with fallback source).
/// 5. App fullscreen (force managed, fallback source).
/// 6. AX attribute fetch failed (explicit float user rule wins; else undecided).
/// 7. Heuristic classification from AX facts.
func solveWindowDecisionKernel(
    matchedUserAction: WindowRuleLayoutAction?,
    matchedBuiltInAction: WindowRuleLayoutAction?,
    matchedBuiltInSourceKind: WindowDecisionBuiltInSourceKind?,
    specialCaseKind: WindowDecisionSpecialCaseKind,
    facts: AXWindowFacts,
    titleRequired: Bool,
    appFullscreen: Bool
) -> WindowDecisionKernelOutput {
    if let userAction = matchedUserAction,
       let disposition = explicitDisposition(for: userAction)
    {
        return WindowDecisionKernelOutput(
            disposition: disposition,
            sourceKind: .userRule,
            builtInSourceKind: nil,
            layoutDecisionKind: .explicitLayout,
            deferredReason: nil,
            heuristicReasons: []
        )
    }

    if let builtInAction = matchedBuiltInAction,
       let disposition = explicitDisposition(for: builtInAction)
    {
        return WindowDecisionKernelOutput(
            disposition: disposition,
            sourceKind: .builtInRule,
            builtInSourceKind: matchedBuiltInSourceKind,
            layoutDecisionKind: .explicitLayout,
            deferredReason: nil,
            heuristicReasons: []
        )
    }

    if specialCaseKind == .cleanShotRecordingOverlay {
        return WindowDecisionKernelOutput(
            disposition: .floating,
            sourceKind: .builtInRule,
            builtInSourceKind: .cleanShotRecordingOverlay,
            layoutDecisionKind: .explicitLayout,
            deferredReason: nil,
            heuristicReasons: []
        )
    }

    if titleRequired, facts.title == nil {
        let fallback = fallbackSourceIncludingBuiltIn(
            userAction: matchedUserAction,
            builtInAction: matchedBuiltInAction,
            builtInSourceKind: matchedBuiltInSourceKind
        )
        return WindowDecisionKernelOutput(
            disposition: .undecided,
            sourceKind: fallback.sourceKind,
            builtInSourceKind: fallback.builtInSourceKind,
            layoutDecisionKind: .fallbackLayout,
            deferredReason: .requiredTitleMissing,
            heuristicReasons: []
        )
    }

    if appFullscreen {
        let fallback = fallbackSourceIncludingBuiltIn(
            userAction: matchedUserAction,
            builtInAction: matchedBuiltInAction,
            builtInSourceKind: matchedBuiltInSourceKind
        )
        return WindowDecisionKernelOutput(
            disposition: .managed,
            sourceKind: fallback.sourceKind,
            builtInSourceKind: fallback.builtInSourceKind,
            layoutDecisionKind: .fallbackLayout,
            deferredReason: nil,
            heuristicReasons: []
        )
    }

    if !facts.attributeFetchSucceeded {
        if matchedUserAction == .float {
            return WindowDecisionKernelOutput(
                disposition: .floating,
                sourceKind: .userRule,
                builtInSourceKind: nil,
                layoutDecisionKind: .fallbackLayout,
                deferredReason: nil,
                heuristicReasons: [.attributeFetchFailed]
            )
        }

        return WindowDecisionKernelOutput(
            disposition: .undecided,
            sourceKind: matchedUserAction != nil ? .userRule : .heuristic,
            builtInSourceKind: nil,
            layoutDecisionKind: .fallbackLayout,
            deferredReason: .attributeFetchFailed,
            heuristicReasons: [.attributeFetchFailed]
        )
    }

    let heuristic = classifyHeuristics(facts: facts)
    return WindowDecisionKernelOutput(
        disposition: heuristic.disposition,
        sourceKind: matchedUserAction != nil ? .userRule : .heuristic,
        builtInSourceKind: nil,
        layoutDecisionKind: .fallbackLayout,
        deferredReason: heuristic.disposition == .undecided ? .attributeFetchFailed : nil,
        heuristicReasons: heuristic.reasons
    )
}

private func explicitDisposition(
    for action: WindowRuleLayoutAction
) -> WindowDecisionDisposition? {
    switch action {
    case .tile: .managed
    case .float: .floating
    case .auto: nil
    }
}

private struct FallbackSource {
    var sourceKind: WindowDecisionKernelSourceKind
    var builtInSourceKind: WindowDecisionBuiltInSourceKind?
}

private func fallbackSourceIncludingBuiltIn(
    userAction: WindowRuleLayoutAction?,
    builtInAction: WindowRuleLayoutAction?,
    builtInSourceKind: WindowDecisionBuiltInSourceKind?
) -> FallbackSource {
    if userAction != nil {
        return FallbackSource(sourceKind: .userRule, builtInSourceKind: nil)
    }
    if builtInAction != nil {
        return FallbackSource(sourceKind: .builtInRule, builtInSourceKind: builtInSourceKind)
    }
    return FallbackSource(sourceKind: .heuristic, builtInSourceKind: nil)
}

private struct HeuristicClassification {
    var disposition: WindowDecisionDisposition
    var reasons: [AXWindowHeuristicReason]
}

private func classifyHeuristics(facts: AXWindowFacts) -> HeuristicClassification {
    if !facts.attributeFetchSucceeded {
        return HeuristicClassification(
            disposition: .undecided,
            reasons: [.attributeFetchFailed]
        )
    }

    let hasAnyButton = facts.hasCloseButton
        || facts.hasFullscreenButton
        || facts.hasZoomButton
        || facts.hasMinimizeButton
    let subroleIsStandard = facts.subrole == (kAXStandardWindowSubrole as String)
    let subroleIsNonStandard: Bool = {
        guard let subrole = facts.subrole else { return false }
        return subrole != (kAXStandardWindowSubrole as String)
    }()

    if facts.appPolicy == .accessory, !facts.hasCloseButton {
        return HeuristicClassification(
            disposition: .floating,
            reasons: [.accessoryWithoutClose]
        )
    }

    if !hasAnyButton, !subroleIsStandard {
        return HeuristicClassification(
            disposition: .floating,
            reasons: [.noButtonsOnNonStandardSubrole]
        )
    }

    if subroleIsNonStandard {
        return HeuristicClassification(
            disposition: .floating,
            reasons: [.nonStandardSubrole]
        )
    }

    if !facts.hasFullscreenButton {
        return HeuristicClassification(
            disposition: .floating,
            reasons: [.missingFullscreenButton]
        )
    }

    if facts.fullscreenButtonEnabled != true {
        return HeuristicClassification(
            disposition: .floating,
            reasons: [.disabledFullscreenButton]
        )
    }

    return HeuristicClassification(disposition: .managed, reasons: [])
}
