import Foundation

enum BenchmarkBaselines {
    struct Phase2Navigation: Decodable {
        let date: String
        let commit: String
        let navigation_p95_sec: Double
    }

    struct Phase3WindowOps: Decodable {
        let date: String
        let commit: String
        let window_ops_p95_sec: Double
    }

    private static var benchmarksDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Benchmarks")
    }

    static func loadPhase2Navigation() throws -> Phase2Navigation {
        try loadJSON(named: "phase2-navigation-baseline.json", as: Phase2Navigation.self)
    }

    static func loadPhase3WindowOps() throws -> Phase3WindowOps {
        try loadJSON(named: "phase3-window-ops-baseline.json", as: Phase3WindowOps.self)
    }

    private static func loadJSON<T: Decodable>(named name: String, as type: T.Type) throws -> T {
        let url = benchmarksDirectory.appendingPathComponent(name)
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(T.self, from: data)
    }
}
