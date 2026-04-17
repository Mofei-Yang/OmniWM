import CoreGraphics
import Foundation

/// Post-M3 reducer façade. The algorithm lives in `NativeStateReducer`;
/// this type preserves the long-standing public API (`StateReducer.reduce`,
/// `StateReducer.restoreIntent`, `StateReducer.replay`) used by the rest
/// of the reconcile pipeline.
enum StateReducer {
    static func reduce(
        event: WMEvent,
        existingEntry: WindowModel.Entry?,
        currentSnapshot: ReconcileSnapshot,
        monitors: [Monitor],
        persistedHydration: PersistedHydrationMutation? = nil
    ) -> ActionPlan {
        NativeStateReducer.reduce(
            event: event,
            existingEntry: existingEntry,
            currentSnapshot: currentSnapshot,
            monitors: monitors,
            persistedHydration: persistedHydration
        )
    }

    static func restoreIntent(
        for entry: WindowModel.Entry,
        monitors: [Monitor]
    ) -> RestoreIntent {
        NativeStateReducer.restoreIntent(for: entry, monitors: monitors)
    }

    static func replay(_ trace: [ReconcileTraceRecord]) -> [ActionPlan] {
        trace.map(\.plan)
    }
}
