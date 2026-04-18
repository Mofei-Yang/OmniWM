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

typealias ReconcileTraceRecord = EngineTraceRecord
typealias ReconcileInvariantViolation = EngineInvariantViolation
typealias ReconcileTxn = EngineTransaction
typealias ReconcileTraceRecorder = EngineTraceRecorder
