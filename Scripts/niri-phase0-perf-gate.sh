#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

BASELINE_REPORT="${REPO_ROOT}/benchmarks/niri/phase0-baseline.json"
LATEST_REPORT="${REPO_ROOT}/dist/benchmarks/niri-phase0-latest.json"

if [[ ! -f "${BASELINE_REPORT}" ]]; then
    echo "Missing baseline report: ${BASELINE_REPORT}" >&2
    exit 1
fi

"${REPO_ROOT}/Scripts/niri-phase0-benchmark.sh"

if [[ ! -f "${LATEST_REPORT}" ]]; then
    echo "Missing latest report after benchmark run: ${LATEST_REPORT}" >&2
    exit 1
fi

echo "==> Comparing p95/p99 against baseline"

swift - "${BASELINE_REPORT}" "${LATEST_REPORT}" <<'SWIFT'
import Foundation

struct Stats: Decodable {
    let p95Ms: Double
    let p99Ms: Double
}

struct Report: Decodable {
    let metrics: [String: Stats]
}

let args = CommandLine.arguments
guard args.count == 3 else {
    fputs("Expected baseline and latest report paths.\n", stderr)
    exit(2)
}

let baselineURL = URL(fileURLWithPath: args[1])
let latestURL = URL(fileURLWithPath: args[2])

let decoder = JSONDecoder()
let baseline = try decoder.decode(Report.self, from: Data(contentsOf: baselineURL))
let latest = try decoder.decode(Report.self, from: Data(contentsOf: latestURL))

let hotPaths = baseline.metrics.keys.sorted()
var failures: [String] = []

for hotPath in hotPaths {
    guard let baselineStats = baseline.metrics[hotPath] else { continue }
    guard let latestStats = latest.metrics[hotPath] else {
        failures.append("\(hotPath): missing in latest report")
        continue
    }

    let p95Delta = latestStats.p95Ms - baselineStats.p95Ms
    let p99Delta = latestStats.p99Ms - baselineStats.p99Ms

    let p95OK = latestStats.p95Ms <= baselineStats.p95Ms
    let p99OK = latestStats.p99Ms <= baselineStats.p99Ms
    let status = (p95OK && p99OK) ? "OK" : "REGRESSION"

    print(
        "\(status) \(hotPath): " +
            "p95 latest=\(String(format: "%.6f", latestStats.p95Ms)) " +
            "baseline=\(String(format: "%.6f", baselineStats.p95Ms)) " +
            "delta=\(String(format: "%+.6f", p95Delta)); " +
            "p99 latest=\(String(format: "%.6f", latestStats.p99Ms)) " +
            "baseline=\(String(format: "%.6f", baselineStats.p99Ms)) " +
            "delta=\(String(format: "%+.6f", p99Delta))"
    )

    if !p95OK || !p99OK {
        failures.append(hotPath)
    }
}

if !failures.isEmpty {
    fputs("Performance gate failed for: \(failures.joined(separator: ", "))\n", stderr)
    exit(1)
}

print("Performance gate passed (no p95/p99 regressions).")
SWIFT
