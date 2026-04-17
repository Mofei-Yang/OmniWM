enum CoordinationCore {
    static func step(
        snapshot: WMSnapshot,
        event: WMEvent
    ) -> CoordinationResult {
        switch event {
        case .refreshRequested, .refreshCompleted:
            let result = RefreshPlanner.step(snapshot: snapshot, event: event)
            return CoordinationResult(
                snapshot: result.snapshot,
                decision: result.decision,
                plan: result.plan
            )

        case .focusRequested, .activationObserved:
            let result = FocusPlanner.step(snapshot: snapshot, event: event)
            return CoordinationResult(
                snapshot: result.snapshot,
                decision: result.decision,
                plan: result.plan
            )

        default:
            preconditionFailure("CoordinationCore received non-coordination event \(event)")
        }
    }
}
