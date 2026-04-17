enum OrchestrationCore {
    static func step(
        snapshot: WMSnapshot,
        event: WMEvent
    ) -> OrchestrationResult {
        switch event {
        case .refreshRequested, .refreshCompleted:
            let result = RefreshPlanner.step(snapshot: snapshot, event: event)
            return OrchestrationResult(
                snapshot: result.snapshot,
                decision: result.decision,
                plan: result.plan
            )

        case .focusRequested, .activationObserved:
            let result = FocusPlanner.step(snapshot: snapshot, event: event)
            return OrchestrationResult(
                snapshot: result.snapshot,
                decision: result.decision,
                plan: result.plan
            )

        default:
            preconditionFailure("OrchestrationCore received non-orchestration event \(event)")
        }
    }
}
