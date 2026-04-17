import Foundation

@MainActor
final class RuntimeStore {
    private let traceRecorder: ReconcileTraceRecorder
    private let nowProvider: () -> Date

    init(
        traceRecorder: ReconcileTraceRecorder,
        nowProvider: @escaping () -> Date = Date.init
    ) {
        self.traceRecorder = traceRecorder
        self.nowProvider = nowProvider
    }

    @discardableResult
    func transact(
        event: WMEvent,
        existingEntry: WindowModel.Entry?,
        monitors: [Monitor],
        persistedHydration: PersistedHydrationMutation? = nil,
        snapshot: () -> WMSnapshot,
        applyPlan: (ActionPlan, WindowToken?) -> ActionPlan
    ) -> ReconcileTxn {
        let currentSnapshot = snapshot()
        let normalizedEvent = EventNormalizer.normalize(
            event: event,
            existingEntry: existingEntry,
            monitors: monitors
        )
        let plan = Reducer.reduce(
            event: normalizedEvent,
            existingEntry: existingEntry,
            currentSnapshot: currentSnapshot,
            monitors: monitors,
            persistedHydration: persistedHydration
        )
        let resolvedPlan = applyPlan(plan, normalizedEvent.token)
        return record(
            event: event,
            normalizedEvent: normalizedEvent,
            plan: resolvedPlan,
            snapshot: snapshot()
        )
    }

    @discardableResult
    func record(
        event: WMEvent,
        normalizedEvent: WMEvent? = nil,
        plan: ActionPlan,
        snapshot: WMSnapshot
    ) -> ReconcileTxn {
        let invariantViolations = InvariantChecks.validate(snapshot: snapshot)
        var tracedPlan = plan
        if !invariantViolations.isEmpty {
            tracedPlan.notes.append(contentsOf: invariantViolations.map(\.traceNote))
        }

        let txn = ReconcileTxn(
            timestamp: nowProvider(),
            event: event,
            normalizedEvent: normalizedEvent ?? event,
            plan: tracedPlan,
            snapshot: snapshot,
            invariantViolations: invariantViolations
        )
        traceRecorder.append(transaction: txn)
        return txn
    }
}
