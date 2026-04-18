import Foundation

struct EngineTraceRecord: Equatable {
    let sequence: UInt64
    let timestamp: Date
    let event: WMEvent
    let normalizedEvent: WMEvent
    let plan: ActionPlan
    let snapshot: WMSnapshot
    let invariantViolations: [EngineInvariantViolation]
}

struct EngineInvariantViolation: Equatable {
    let code: String
    let message: String

    var traceNote: String {
        "invariant[\(code)]=\(message)"
    }
}

struct EngineTransaction: Equatable {
    let timestamp: Date
    let event: WMEvent
    let normalizedEvent: WMEvent
    let plan: ActionPlan
    let snapshot: WMSnapshot
    let invariantViolations: [EngineInvariantViolation]
}

@MainActor
final class EngineTraceRecorder {
    private static let defaultLimit = 256

    private let limit: Int
    private var nextSequence: UInt64 = 1
    private var records: [EngineTraceRecord] = []

    init(limit: Int = defaultLimit) {
        self.limit = max(1, limit)
    }

    func append(
        event: WMEvent,
        normalizedEvent: WMEvent? = nil,
        plan: ActionPlan,
        snapshot: WMSnapshot,
        invariantViolations: [EngineInvariantViolation] = [],
        timestamp: Date = Date()
    ) {
        let record = EngineTraceRecord(
            sequence: nextSequence,
            timestamp: timestamp,
            event: event,
            normalizedEvent: normalizedEvent ?? event,
            plan: plan,
            snapshot: snapshot,
            invariantViolations: invariantViolations
        )
        nextSequence += 1
        if records.count == limit {
            records.removeFirst()
        }
        records.append(record)
    }

    func append(transaction: EngineTransaction) {
        append(
            event: transaction.event,
            normalizedEvent: transaction.normalizedEvent,
            plan: transaction.plan,
            snapshot: transaction.snapshot,
            invariantViolations: transaction.invariantViolations,
            timestamp: transaction.timestamp
        )
    }

    func snapshot() -> [EngineTraceRecord] {
        records
    }

    func reset() {
        records.removeAll(keepingCapacity: true)
        nextSequence = 1
    }
}

enum EngineDebugDump {
    static func snapshot(_ snapshot: WMSnapshot) -> String {
        var lines: [String] = [
            "topology displays=\(snapshot.topologyProfile.displays.count)",
            "focused=\(snapshot.focusedToken.map(String.init(describing:)) ?? "nil")",
            "pending-focus=\(snapshot.focusSession.pendingManagedFocus.token.map(String.init(describing:)) ?? "nil")",
            "focus-lease=\(snapshot.focusSession.focusLease?.owner.rawValue ?? "nil")",
            "non-managed-focus=\(snapshot.focusSession.isNonManagedFocusActive)",
            "app-fullscreen=\(snapshot.focusSession.isAppFullscreenActive)",
            "interaction-monitor=\(snapshot.interactionMonitorId.map(String.init(describing:)) ?? "nil")",
            "previous-interaction-monitor=\(snapshot.previousInteractionMonitorId.map(String.init(describing:)) ?? "nil")",
        ]

        for window in snapshot.windows {
            lines.append(
                "\(window.token) workspace=\(window.workspaceId.uuidString) mode=\(window.mode) phase=\(window.lifecyclePhase.rawValue) observed=\(describe(window.observedState)) desired=\(window.desiredState.summary)"
            )
        }

        return lines.joined(separator: "\n")
    }

    static func trace(_ records: [EngineTraceRecord], limit: Int? = nil) -> String {
        let truncated = limit.map { Array(records.suffix(max(0, $0))) } ?? records
        if truncated.isEmpty {
            return "trace empty"
        }

        return truncated.map { record in
            var parts = [
                "#\(record.sequence)",
                record.timestamp.ISO8601Format(),
                "event=\(record.event.summary)",
            ]
            if record.normalizedEvent != record.event {
                parts.append("normalized=\(record.normalizedEvent.summary)")
            }
            if !record.plan.summary.isEmpty {
                parts.append("plan=\(record.plan.summary)")
            }
            if !record.invariantViolations.isEmpty {
                parts.append(
                    "violations=\(record.invariantViolations.map(\.code).joined(separator: ","))"
                )
            }
            return parts.joined(separator: " ")
        }
        .joined(separator: "\n")
    }

    private static func describe(_ state: ObservedWindowState) -> String {
        [
            "workspace=\(state.workspaceId?.uuidString ?? "nil")",
            "monitor=\(state.monitorId.map(String.init(describing:)) ?? "nil")",
            "visible=\(state.isVisible)",
            "focused=\(state.isFocused)",
            "fullscreen=\(state.isNativeFullscreen)",
        ]
        .joined(separator: ",")
    }
}
