import Foundation
import XCTest

@testable import OmniWM

@MainActor
final class NiriPhase0BenchmarkTests: XCTestCase {
    private static var cachedReport: NiriPhase0BenchmarkReport?
    private static var cachedScenario: NiriPhase0Scenario?

    func testPercentilesAreMonotonic() {
        let stats = NiriLatencyStats.from(samplesNanoseconds: [
            9_100_000,
            1_300_000,
            5_500_000,
            2_200_000,
            8_400_000,
            3_700_000,
            6_000_000
        ])

        XCTAssertGreaterThan(stats.count, 0)
        XCTAssertLessThanOrEqual(stats.p50Ms, stats.p95Ms)
        XCTAssertLessThanOrEqual(stats.p95Ms, stats.p99Ms)
    }

    func testEmptyAndLowSampleStatsAreStable() {
        let empty = NiriLatencyStats.from(samplesNanoseconds: [])
        XCTAssertEqual(empty, .empty)

        let single = NiriLatencyStats.from(samplesNanoseconds: [1_250_000])
        XCTAssertEqual(single.count, 1)
        XCTAssertEqual(single.minMs, single.meanMs, accuracy: 0.000_001)
        XCTAssertEqual(single.meanMs, single.p50Ms, accuracy: 0.000_001)
        XCTAssertEqual(single.p50Ms, single.p95Ms, accuracy: 0.000_001)
        XCTAssertEqual(single.p95Ms, single.p99Ms, accuracy: 0.000_001)
        XCTAssertEqual(single.p99Ms, single.maxMs, accuracy: 0.000_001)
    }

    func testResetClearsSamples() throws {
        try requireBenchmarkEnabled()

        NiriLatencyProbe.reset()
        NiriLatencyProbe.record(.layoutPass, elapsedNanoseconds: 2_000_000)
        let before = NiriLatencyProbe.snapshot()
        XCTAssertEqual(before[.layoutPass]?.count, 1)

        NiriLatencyProbe.reset()
        let after = NiriLatencyProbe.snapshot()
        XCTAssertEqual(after[.layoutPass]?.count, 0)
    }

    func testReplayProducesSamplesForAllHotPaths() throws {
        try requireBenchmarkEnabled()
        let report = try benchmarkReport()

        for hotPath in NiriLatencyHotPath.allCases {
            let stats = try XCTUnwrap(report.metrics[hotPath.rawValue])
            XCTAssertGreaterThan(stats.count, 0, "Expected non-zero samples for \(hotPath.rawValue)")
        }
    }

    func testReplayReproducibilityForCountsAndSchema() throws {
        try requireBenchmarkEnabled()
        let scenario = try loadScenario()

        let first = try NiriReplayHarness.runScenario(scenario)
        let second = try NiriReplayHarness.runScenario(scenario)

        XCTAssertEqual(Set(first.metrics.keys), Set(second.metrics.keys))
        XCTAssertEqual(first.sampleCounts, second.sampleCounts)
        XCTAssertEqual(first.expectedSamplesByPath, second.expectedSamplesByPath)
        XCTAssertEqual(first.sampleCounts, first.expectedSamplesByPath)
        XCTAssertEqual(second.sampleCounts, second.expectedSamplesByPath)
    }

    func testBaselineContractDecodes() throws {
        let baselineURL = repoRootURL()
            .appendingPathComponent("benchmarks")
            .appendingPathComponent("niri")
            .appendingPathComponent("phase0-baseline.json")

        let data = try Data(contentsOf: baselineURL)
        let baseline = try JSONDecoder().decode(NiriPhase0BenchmarkReport.self, from: data)

        XCTAssertEqual(baseline.schemaVersion, 1)
        for hotPath in NiriLatencyHotPath.allCases {
            XCTAssertNotNil(baseline.metrics[hotPath.rawValue])
        }
    }

    func testReportIsWrittenWhenPathIsConfigured() throws {
        try requireBenchmarkEnabled()
        _ = try benchmarkReport()

        guard let path = ProcessInfo.processInfo.environment["OMNI_NIRI_PHASE0_REPORT_PATH"],
              !path.isEmpty else {
            throw XCTSkip("OMNI_NIRI_PHASE0_REPORT_PATH not set")
        }

        let reportURL = URL(fileURLWithPath: path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reportURL.path))

        let data = try Data(contentsOf: reportURL)
        let decoded = try JSONDecoder().decode(NiriPhase0BenchmarkReport.self, from: data)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.scenarioName, try loadScenario().name)
    }

    private func benchmarkReport() throws -> NiriPhase0BenchmarkReport {
        if let cached = Self.cachedReport {
            return cached
        }

        let scenario = try loadScenario()
        let report = try NiriReplayHarness.runScenario(scenario)
        Self.cachedScenario = scenario
        Self.cachedReport = report
        return report
    }

    private func loadScenario() throws -> NiriPhase0Scenario {
        if let cached = Self.cachedScenario {
            return cached
        }

        guard let url = Bundle.module.url(forResource: "phase0-replay", withExtension: "json") else {
            throw XCTSkip("Missing phase0-replay.json fixture")
        }
        return try NiriReplayHarness.loadScenario(from: url)
    }

    private func requireBenchmarkEnabled() throws {
        if !NiriLatencyProbe.isEnabled {
            throw XCTSkip("Set \(NiriLatencyProbe.environmentKey)=1 to run benchmark replay tests")
        }
    }

    private func repoRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
