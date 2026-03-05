import Dispatch
import Foundation

enum NiriLatencyHotPath: String, CaseIterable, Codable {
    case layoutPass
    case windowMove
    case resizeDragUpdate
    case navigationStep
    case workspaceMove
}

struct NiriLatencyStats: Codable, Equatable {
    let count: Int
    let minMs: Double
    let meanMs: Double
    let p50Ms: Double
    let p95Ms: Double
    let p99Ms: Double
    let maxMs: Double

    static let empty = NiriLatencyStats(
        count: 0,
        minMs: 0,
        meanMs: 0,
        p50Ms: 0,
        p95Ms: 0,
        p99Ms: 0,
        maxMs: 0
    )

    static func from(samplesNanoseconds: [UInt64]) -> NiriLatencyStats {
        guard !samplesNanoseconds.isEmpty else {
            return .empty
        }

        let sorted = samplesNanoseconds.sorted()
        let count = sorted.count
        let minValue = sorted[0]
        let maxValue = sorted[count - 1]

        var totalNanoseconds: Double = 0
        for value in sorted {
            totalNanoseconds += Double(value)
        }

        let p50 = nearestRank(sorted: sorted, percentile: 0.50)
        let p95 = nearestRank(sorted: sorted, percentile: 0.95)
        let p99 = nearestRank(sorted: sorted, percentile: 0.99)

        return NiriLatencyStats(
            count: count,
            minMs: toMilliseconds(minValue),
            meanMs: toMilliseconds(totalNanoseconds / Double(count)),
            p50Ms: toMilliseconds(p50),
            p95Ms: toMilliseconds(p95),
            p99Ms: toMilliseconds(p99),
            maxMs: toMilliseconds(maxValue)
        )
    }

    private static func nearestRank(sorted: [UInt64], percentile: Double) -> UInt64 {
        guard !sorted.isEmpty else { return 0 }
        let count = sorted.count
        let rank = max(1, Int(ceil(percentile * Double(count))))
        let index = min(count - 1, rank - 1)
        return sorted[index]
    }

    private static func toMilliseconds(_ nanoseconds: UInt64) -> Double {
        Double(nanoseconds) / 1_000_000.0
    }

    private static func toMilliseconds(_ nanoseconds: Double) -> Double {
        nanoseconds / 1_000_000.0
    }
}

enum NiriLatencyProbe {
    static let environmentKey = "OMNI_NIRI_PHASE0_BENCH"

    private static let enabled = ProcessInfo.processInfo.environment[environmentKey] == "1"
    private nonisolated(unsafe) static var samplesByPath: [NiriLatencyHotPath: [UInt64]] = Dictionary(
        uniqueKeysWithValues: NiriLatencyHotPath.allCases.map { ($0, []) }
    )
    private static let lock = NSLock()

    static var isEnabled: Bool {
        enabled
    }

    @inline(__always)
    static func measure<T>(_ hotPath: NiriLatencyHotPath, _ body: () throws -> T) rethrows -> T {
        guard enabled else {
            return try body()
        }

        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            let end = DispatchTime.now().uptimeNanoseconds
            record(hotPath, elapsedNanoseconds: end &- start)
        }
        return try body()
    }

    static func record(_ hotPath: NiriLatencyHotPath, elapsedNanoseconds: UInt64) {
        guard enabled else { return }

        lock.lock()
        samplesByPath[hotPath, default: []].append(elapsedNanoseconds)
        lock.unlock()
    }

    @inline(__always)
    static func begin(_ hotPath: NiriLatencyHotPath) -> (hotPath: NiriLatencyHotPath, startedAt: UInt64)? {
        guard enabled else { return nil }
        return (hotPath: hotPath, startedAt: DispatchTime.now().uptimeNanoseconds)
    }

    @inline(__always)
    static func end(_ token: (hotPath: NiriLatencyHotPath, startedAt: UInt64)?) {
        guard let token else { return }
        let endTime = DispatchTime.now().uptimeNanoseconds
        record(token.hotPath, elapsedNanoseconds: endTime &- token.startedAt)
    }

    static func reset() {
        guard enabled else { return }

        lock.lock()
        for hotPath in NiriLatencyHotPath.allCases {
            samplesByPath[hotPath]?.removeAll(keepingCapacity: true)
        }
        lock.unlock()
    }

    static func snapshot() -> [NiriLatencyHotPath: NiriLatencyStats] {
        guard enabled else {
            return emptySnapshot()
        }

        lock.lock()
        let captured = samplesByPath
        lock.unlock()

        var result: [NiriLatencyHotPath: NiriLatencyStats] = [:]
        result.reserveCapacity(NiriLatencyHotPath.allCases.count)
        for hotPath in NiriLatencyHotPath.allCases {
            let samples = captured[hotPath] ?? []
            result[hotPath] = NiriLatencyStats.from(samplesNanoseconds: samples)
        }
        return result
    }

    static func emptySnapshot() -> [NiriLatencyHotPath: NiriLatencyStats] {
        var result: [NiriLatencyHotPath: NiriLatencyStats] = [:]
        result.reserveCapacity(NiriLatencyHotPath.allCases.count)
        for hotPath in NiriLatencyHotPath.allCases {
            result[hotPath] = .empty
        }
        return result
    }
}
