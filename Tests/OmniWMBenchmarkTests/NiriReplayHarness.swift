import ApplicationServices
import Foundation

@testable import OmniWM

struct NiriPhase0Scenario: Codable {
    struct Seed: Codable {
        struct Workspace: Codable {
            let name: String
            let windowCount: Int
        }

        struct MonitorSeed: Codable {
            struct Insets: Codable {
                let left: Double
                let right: Double
                let top: Double
                let bottom: Double
            }

            let displayId: UInt32
            let width: Double
            let height: Double
            let visibleInsets: Insets
        }

        let maxWindowsPerColumn: Int
        let maxVisibleColumns: Int
        let gap: Double
        let scale: Double
        let monitor: MonitorSeed
        let workspaces: [Workspace]
    }

    struct Event: Codable {
        enum Kind: String, Codable {
            case layoutPass
            case windowMove
            case resizeDragUpdate
            case navigationStep
            case workspaceMove
        }

        let kind: Kind
        let count: Int
    }

    let name: String
    let warmupIterations: Int
    let measuredIterations: Int
    let seed: Seed
    let events: [Event]
}

struct NiriPhase0BenchmarkReport: Codable {
    let schemaVersion: Int
    let scenarioName: String
    let generatedAt: String
    let warmupIterations: Int
    let measuredIterations: Int
    let sampleCounts: [String: Int]
    let expectedSamplesByPath: [String: Int]
    let metrics: [String: NiriLatencyStats]
}

@MainActor
enum NiriReplayHarness {
    private static let reportSchemaVersion = 1
    private static let reportPathEnvironmentKey = "OMNI_NIRI_PHASE0_REPORT_PATH"

    enum Error: Swift.Error, CustomStringConvertible {
        case invalidScenario(String)
        case missingWindow(String)
        case operationFailed(String)

        var description: String {
            switch self {
            case let .invalidScenario(message):
                return "Invalid scenario: \(message)"
            case let .missingWindow(message):
                return "Missing window: \(message)"
            case let .operationFailed(message):
                return "Operation failed: \(message)"
            }
        }
    }

    private struct Fixture {
        let engine: NiriLayoutEngine
        let monitor: Monitor
        let workingArea: WorkingAreaContext
        let gaps: LayoutGaps
        let primaryWorkspaceId: WorkspaceDescriptor.ID
        let secondaryWorkspaceId: WorkspaceDescriptor.ID
        let trackedHandle: WindowHandle
        var primaryState: ViewportState
        var secondaryState: ViewportState
    }

    static func loadScenario(from url: URL) throws -> NiriPhase0Scenario {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(NiriPhase0Scenario.self, from: data)
    }

    static func runScenario(_ scenario: NiriPhase0Scenario) throws -> NiriPhase0BenchmarkReport {
        guard scenario.workspacesCount >= 2 else {
            throw Error.invalidScenario("at least two workspaces are required")
        }
        guard !scenario.events.isEmpty else {
            throw Error.invalidScenario("events cannot be empty")
        }
        guard scenario.warmupIterations >= 0 else {
            throw Error.invalidScenario("warmupIterations cannot be negative")
        }
        guard scenario.measuredIterations > 0 else {
            throw Error.invalidScenario("measuredIterations must be greater than zero")
        }

        for _ in 0 ..< scenario.warmupIterations {
            var fixture = try makeFixture(seed: scenario.seed)
            try replay(events: scenario.events, fixture: &fixture)
        }

        NiriLatencyProbe.reset()

        for _ in 0 ..< scenario.measuredIterations {
            var fixture = try makeFixture(seed: scenario.seed)
            try replay(events: scenario.events, fixture: &fixture)
        }

        let snapshot = NiriLatencyProbe.snapshot()
        let metrics = metricsByName(from: snapshot)
        let sampleCounts = sampleCountsByName(from: metrics)
        let expectedSamples = expectedSamplesByPath(
            events: scenario.events,
            measuredIterations: scenario.measuredIterations
        )

        let report = NiriPhase0BenchmarkReport(
            schemaVersion: reportSchemaVersion,
            scenarioName: scenario.name,
            generatedAt: timestampNowISO8601(),
            warmupIterations: scenario.warmupIterations,
            measuredIterations: scenario.measuredIterations,
            sampleCounts: sampleCounts,
            expectedSamplesByPath: expectedSamples,
            metrics: metrics
        )

        try writeReportIfRequested(report)
        return report
    }

    static func writeReportIfRequested(_ report: NiriPhase0BenchmarkReport) throws {
        guard let outputPath = ProcessInfo.processInfo.environment[reportPathEnvironmentKey],
              !outputPath.isEmpty else {
            return
        }

        let outputURL = URL(fileURLWithPath: outputPath)
        let directoryURL = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        try data.write(to: outputURL, options: .atomic)
    }

    private static func makeFixture(seed: NiriPhase0Scenario.Seed) throws -> Fixture {
        let monitorFrame = CGRect(
            x: 0,
            y: 0,
            width: seed.monitor.width,
            height: seed.monitor.height
        )
        let visibleFrame = CGRect(
            x: monitorFrame.minX + seed.monitor.visibleInsets.left,
            y: monitorFrame.minY + seed.monitor.visibleInsets.bottom,
            width: max(1, monitorFrame.width - seed.monitor.visibleInsets.left - seed.monitor.visibleInsets.right),
            height: max(1, monitorFrame.height - seed.monitor.visibleInsets.top - seed.monitor.visibleInsets.bottom)
        )
        let monitor = Monitor(
            id: .init(displayId: CGDirectDisplayID(seed.monitor.displayId)),
            displayId: CGDirectDisplayID(seed.monitor.displayId),
            frame: monitorFrame,
            visibleFrame: visibleFrame,
            hasNotch: false,
            name: "NiriPhase0BenchmarkMonitor"
        )

        let engine = NiriLayoutEngine(
            maxWindowsPerColumn: seed.maxWindowsPerColumn,
            maxVisibleColumns: seed.maxVisibleColumns,
            infiniteLoop: false
        )
        engine.maxVisibleColumns = seed.maxVisibleColumns

        let primaryWorkspace = WorkspaceDescriptor(name: seed.workspaces[0].name)
        let secondaryWorkspace = WorkspaceDescriptor(name: seed.workspaces[1].name)

        engine.moveWorkspace(primaryWorkspace.id, to: monitor.id, monitor: monitor)
        engine.moveWorkspace(secondaryWorkspace.id, to: monitor.id, monitor: monitor)

        let primaryHandles = try populateWorkspace(
            engine: engine,
            workspaceId: primaryWorkspace.id,
            windowCount: max(2, seed.workspaces[0].windowCount)
        )
        _ = try populateWorkspace(
            engine: engine,
            workspaceId: secondaryWorkspace.id,
            windowCount: max(1, seed.workspaces[1].windowCount)
        )

        var primaryState = ViewportState()
        var secondaryState = ViewportState()

        if let splitSource = primaryHandles.dropFirst().first,
           let splitNode = engine.findNode(for: splitSource)
        {
            _ = engine.insertWindowInNewColumn(
                splitNode,
                insertIndex: 1,
                in: primaryWorkspace.id,
                state: &primaryState,
                workingFrame: visibleFrame,
                gaps: CGFloat(seed.gap)
            )
        }

        guard let trackedHandle = primaryHandles.first,
              let trackedNode = engine.findNode(for: trackedHandle) else {
            throw Error.missingWindow("primary workspace has no tracked node")
        }

        primaryState.selectedNodeId = trackedNode.id
        engine.activateWindow(trackedNode.id)

        if let secondaryNode = engine.columns(in: secondaryWorkspace.id).first?.windowNodes.first {
            secondaryState.selectedNodeId = secondaryNode.id
            engine.activateWindow(secondaryNode.id)
        }

        let workingArea = WorkingAreaContext(
            workingFrame: visibleFrame,
            viewFrame: monitorFrame,
            scale: CGFloat(seed.scale)
        )
        let gaps = LayoutGaps(horizontal: CGFloat(seed.gap), vertical: CGFloat(seed.gap), outer: .zero)

        return Fixture(
            engine: engine,
            monitor: monitor,
            workingArea: workingArea,
            gaps: gaps,
            primaryWorkspaceId: primaryWorkspace.id,
            secondaryWorkspaceId: secondaryWorkspace.id,
            trackedHandle: trackedHandle,
            primaryState: primaryState,
            secondaryState: secondaryState
        )
    }

    private static func populateWorkspace(
        engine: NiriLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        windowCount: Int
    ) throws -> [WindowHandle] {
        guard windowCount > 0 else {
            throw Error.invalidScenario("workspace windowCount must be greater than zero")
        }

        let pid = pid_t(ProcessInfo.processInfo.processIdentifier)
        var handles: [WindowHandle] = []
        handles.reserveCapacity(windowCount)

        for _ in 0 ..< windowCount {
            let handle = WindowHandle(
                id: UUID(),
                pid: pid,
                axElement: AXUIElementCreateApplication(pid)
            )
            let selectedNodeId = engine.columns(in: workspaceId).first?.windowNodes.last?.id
            _ = engine.addWindow(
                handle: handle,
                to: workspaceId,
                afterSelection: selectedNodeId,
                focusedHandle: nil
            )
            handles.append(handle)
        }

        return handles
    }

    private static func replay(events: [NiriPhase0Scenario.Event], fixture: inout Fixture) throws {
        for event in events {
            let repetitions = max(1, event.count)
            for _ in 0 ..< repetitions {
                try execute(event: event.kind, fixture: &fixture)
            }
        }
    }

    private static func execute(event: NiriPhase0Scenario.Event.Kind, fixture: inout Fixture) throws {
        switch event {
        case .layoutPass:
            _ = fixture.engine.calculateCombinedLayoutUsingPools(
                in: fixture.primaryWorkspaceId,
                monitor: fixture.monitor,
                gaps: fixture.gaps,
                state: fixture.primaryState,
                workingArea: fixture.workingArea
            )

        case .windowMove:
            guard let trackedNode = fixture.engine.findNode(for: fixture.trackedHandle) else {
                throw Error.missingWindow("tracked node missing for windowMove")
            }
            _ = fixture.engine.moveWindow(
                trackedNode,
                direction: .down,
                in: fixture.primaryWorkspaceId,
                state: &fixture.primaryState,
                workingFrame: fixture.workingArea.workingFrame,
                gaps: fixture.gaps.horizontal
            )

        case .resizeDragUpdate:
            guard let trackedNode = fixture.engine.findNode(for: fixture.trackedHandle) else {
                throw Error.missingWindow("tracked node missing for resizeDragUpdate")
            }

            let frame = trackedNode.frame ?? CGRect(
                x: fixture.workingArea.workingFrame.midX - 200,
                y: fixture.workingArea.workingFrame.midY - 150,
                width: 400,
                height: 300
            )
            let startLocation = CGPoint(x: frame.maxX - 2, y: frame.midY)

            fixture.engine.clearInteractiveResize()
            guard fixture.engine.interactiveResizeBegin(
                windowId: trackedNode.id,
                edges: [.right],
                startLocation: startLocation,
                in: fixture.primaryWorkspaceId,
                viewOffset: fixture.primaryState.viewOffsetPixels.current()
            ) else {
                throw Error.operationFailed("interactiveResizeBegin returned false")
            }

            _ = fixture.engine.interactiveResizeUpdate(
                currentLocation: CGPoint(x: startLocation.x + 24, y: startLocation.y),
                monitorFrame: fixture.workingArea.workingFrame,
                gaps: fixture.gaps,
                viewportState: { mutate in
                    mutate(&fixture.primaryState)
                }
            )

            fixture.engine.interactiveResizeEnd(
                state: &fixture.primaryState,
                workingFrame: fixture.workingArea.workingFrame,
                gaps: fixture.gaps.horizontal
            )

        case .navigationStep:
            guard let currentSelectionId = fixture.primaryState.selectedNodeId,
                  let currentSelection = fixture.engine.findNode(by: currentSelectionId) else {
                throw Error.missingWindow("selected node missing for navigationStep")
            }

            if let newSelection = fixture.engine.moveSelectionByColumns(
                steps: 1,
                currentSelection: currentSelection,
                in: fixture.primaryWorkspaceId
            ) {
                fixture.primaryState.selectedNodeId = newSelection.id
            }

        case .workspaceMove:
            guard let trackedNode = fixture.engine.findNode(for: fixture.trackedHandle) else {
                throw Error.missingWindow("tracked node missing for workspaceMove")
            }

            guard fixture.engine.moveWindowToWorkspace(
                trackedNode,
                from: fixture.primaryWorkspaceId,
                to: fixture.secondaryWorkspaceId,
                sourceState: &fixture.primaryState,
                targetState: &fixture.secondaryState
            ) != nil else {
                throw Error.operationFailed("moveWindowToWorkspace returned nil")
            }
        }
    }

    private static func metricsByName(
        from snapshot: [NiriLatencyHotPath: NiriLatencyStats]
    ) -> [String: NiriLatencyStats] {
        var metrics: [String: NiriLatencyStats] = [:]
        metrics.reserveCapacity(NiriLatencyHotPath.allCases.count)

        for hotPath in NiriLatencyHotPath.allCases {
            metrics[hotPath.rawValue] = snapshot[hotPath] ?? .empty
        }
        return metrics
    }

    private static func sampleCountsByName(from metrics: [String: NiriLatencyStats]) -> [String: Int] {
        var counts: [String: Int] = [:]
        counts.reserveCapacity(metrics.count)
        for (key, stats) in metrics {
            counts[key] = stats.count
        }
        return counts
    }

    private static func expectedSamplesByPath(
        events: [NiriPhase0Scenario.Event],
        measuredIterations: Int
    ) -> [String: Int] {
        var perIteration: [NiriLatencyHotPath: Int] = Dictionary(
            uniqueKeysWithValues: NiriLatencyHotPath.allCases.map { ($0, 0) }
        )

        for event in events {
            let repetitions = max(1, event.count)
            switch event.kind {
            case .layoutPass:
                perIteration[.layoutPass, default: 0] += repetitions
            case .windowMove:
                perIteration[.windowMove, default: 0] += repetitions
            case .resizeDragUpdate:
                perIteration[.resizeDragUpdate, default: 0] += repetitions
            case .navigationStep:
                perIteration[.navigationStep, default: 0] += repetitions
            case .workspaceMove:
                perIteration[.workspaceMove, default: 0] += repetitions
            }
        }

        var expected: [String: Int] = [:]
        expected.reserveCapacity(NiriLatencyHotPath.allCases.count)
        for hotPath in NiriLatencyHotPath.allCases {
            let count = (perIteration[hotPath] ?? 0) * measuredIterations
            expected[hotPath.rawValue] = count
        }
        return expected
    }

    private static func timestampNowISO8601() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

private extension NiriPhase0Scenario {
    var workspacesCount: Int {
        seed.workspaces.count
    }
}
