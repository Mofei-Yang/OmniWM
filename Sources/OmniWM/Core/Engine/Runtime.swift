import AppKit
import ApplicationServices
import Foundation
import Observation

typealias WMState = WMSnapshot
typealias WMPlan = ActionPlan

@MainActor
protocol PlatformAdapter {
    var windowFocusOperations: WindowFocusOperations { get }
    var activateApplication: (pid_t) -> Void { get }
    var focusSpecificWindow: (pid_t, UInt32, AXUIElement) -> Void { get }
    var raiseWindow: (AXUIElement) -> Void { get }
    var closeWindow: (AXUIElement) -> Void { get }
    var orderWindowAbove: (UInt32) -> Void { get }
    var visibleWindowInfo: () -> [WindowServerInfo] { get }
    var axWindowRef: (UInt32, pid_t) -> AXWindowRef? { get }
    var visibleOwnedWindows: () -> [NSWindow] { get }
    var frontOwnedWindow: (NSWindow) -> Void { get }
    var performMenuAction: (AXUIElement) -> Void { get }
}

extension WMPlatform: PlatformAdapter {}

typealias RefreshCycleId = UInt64
typealias RefreshAttachmentId = UInt64

enum ScheduledRefreshKind: Int, Equatable {
    case relayout
    case immediateRelayout
    case visibilityRefresh
    case windowRemoval
    case fullRescan
}

struct WindowRemovalPayload: Equatable {
    let workspaceId: WorkspaceDescriptor.ID
    let layoutType: LayoutType
    let removedNodeId: NodeId?
    let niriOldFrames: [WindowToken: CGRect]
    let shouldRecoverFocus: Bool
}

struct FollowUpRefresh: Equatable {
    var kind: ScheduledRefreshKind
    var reason: RefreshReason
    var affectedWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
}

struct ScheduledRefresh: Equatable {
    var cycleId: RefreshCycleId
    var kind: ScheduledRefreshKind
    var reason: RefreshReason
    var affectedWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
    var postLayoutAttachmentIds: [RefreshAttachmentId] = []
    var windowRemovalPayloads: [WindowRemovalPayload] = []
    var followUpRefresh: FollowUpRefresh?
    var needsVisibilityReconciliation: Bool = false
    var visibilityReason: RefreshReason?

    init(
        cycleId: RefreshCycleId,
        kind: ScheduledRefreshKind,
        reason: RefreshReason,
        affectedWorkspaceIds: Set<WorkspaceDescriptor.ID> = [],
        postLayoutAttachmentIds: [RefreshAttachmentId] = [],
        windowRemovalPayload: WindowRemovalPayload? = nil
    ) {
        self.cycleId = cycleId
        self.kind = kind
        self.reason = reason
        self.affectedWorkspaceIds = affectedWorkspaceIds
        self.postLayoutAttachmentIds = postLayoutAttachmentIds
        if let windowRemovalPayload {
            windowRemovalPayloads = [windowRemovalPayload]
        }
    }
}

struct CoordinationResult: Equatable {
    var snapshot: WMSnapshot
    var plan: ActionPlan

    init(
        snapshot: WMSnapshot,
        decision: ActionPlan.Decision,
        plan: ActionPlan
    ) {
        var plan = plan
        if plan.decision == nil {
            plan.decision = decision
        }
        self.snapshot = snapshot
        self.plan = plan
    }

    var decision: ActionPlan.Decision {
        guard let decision = plan.decision else {
            preconditionFailure("CoordinationResult missing plan decision")
        }
        return decision
    }
}

enum RuntimeEffectContext {
    case focusRequest
    case activationObserved(
        observedAXRef: AXWindowRef?,
        managedEntry: WindowModel.Entry?,
        source: ActivationEventSource,
        confirmRequest: Bool
    )
    case refresh
}

@MainActor
protocol EffectExecutor {
    func execute(
        _ result: CoordinationResult,
        on controller: WMController,
        context: RuntimeEffectContext
    )
}

enum RuntimeSubmitResult {
    case reconcile(EngineTransaction)
    case coordination(CoordinationResult)
}

struct RuntimeSnapshot {
    var state: WMState
    var configuration: RuntimeConfiguration
}

struct RuntimeTraceRecord {
    let eventId: UInt64
    let timestamp: Date
    let eventSummary: String
    let decisionSummary: String?
    let actionSummaries: [String]
    let focusedToken: WindowToken?
    let pendingFocusedToken: WindowToken?
    let activeRefreshCycleId: RefreshCycleId?
    let pendingRefreshCycleId: RefreshCycleId?
}

struct RuntimeConfiguration {
    struct LayoutConfiguration {
        struct Niri {
            var maxWindowsPerColumn: Int
            var maxVisibleColumns: Int
            var infiniteLoop: Bool
            var centerFocusedColumn: CenterFocusedColumn
            var alwaysCenterSingleColumn: Bool
            var singleWindowAspectRatio: SingleWindowAspectRatio
            var columnWidthPresets: [Double]
            var defaultColumnWidth: Double?
        }

        struct Dwindle {
            var smartSplit: Bool
            var defaultSplitRatio: Double
            var splitWidthMultiplier: Double
            var singleWindowAspectRatio: CGSize
        }

        var gapSize: Double
        var outerGaps: LayoutGaps.OuterGaps
        var niri: Niri
        var dwindle: Dwindle
    }

    var animationsEnabled: Bool
    var appearanceMode: AppearanceMode
    var hotkeyBindings: [HotkeyBinding]
    var hotkeysEnabled: Bool
    var layout: LayoutConfiguration
    var borderConfig: BorderConfig
    var focusFollowsMouse: Bool
    var moveMouseToFocusedWindow: Bool
    var workspaceBarEnabled: Bool
    var preventSleepEnabled: Bool
    var quakeTerminalEnabled: Bool

    var summary: String {
        [
            "animations=\(animationsEnabled)",
            "appearance=\(appearanceMode.rawValue)",
            "hotkeys=\(hotkeysEnabled)",
            "gaps=\(layout.gapSize)",
            "workspace-bar=\(workspaceBarEnabled)",
            "prevent-sleep=\(preventSleepEnabled)",
            "quake=\(quakeTerminalEnabled)",
            "ffm=\(focusFollowsMouse)",
            "mouse-to-focus=\(moveMouseToFocusedWindow)",
            "column-presets=\(layout.niri.columnWidthPresets.count)",
        ]
        .joined(separator: " ")
    }

    @MainActor
    init(settings: SettingsStore) {
        animationsEnabled = settings.animationsEnabled
        appearanceMode = settings.appearanceMode
        hotkeyBindings = settings.hotkeyBindings
        hotkeysEnabled = settings.hotkeysEnabled
        layout = LayoutConfiguration(
            gapSize: settings.gapSize,
            outerGaps: .init(
                left: settings.outerGapLeft,
                right: settings.outerGapRight,
                top: settings.outerGapTop,
                bottom: settings.outerGapBottom
            ),
            niri: .init(
                maxWindowsPerColumn: settings.niriMaxWindowsPerColumn,
                maxVisibleColumns: settings.niriMaxVisibleColumns,
                infiniteLoop: settings.niriInfiniteLoop,
                centerFocusedColumn: settings.niriCenterFocusedColumn,
                alwaysCenterSingleColumn: settings.niriAlwaysCenterSingleColumn,
                singleWindowAspectRatio: settings.niriSingleWindowAspectRatio,
                columnWidthPresets: settings.niriColumnWidthPresets,
                defaultColumnWidth: settings.niriDefaultColumnWidth
            ),
            dwindle: .init(
                smartSplit: settings.dwindleSmartSplit,
                defaultSplitRatio: settings.dwindleDefaultSplitRatio,
                splitWidthMultiplier: settings.dwindleSplitWidthMultiplier,
                singleWindowAspectRatio: settings.dwindleSingleWindowAspectRatio.size
            )
        )
        borderConfig = BorderConfig.from(settings: settings)
        focusFollowsMouse = settings.focusFollowsMouse
        moveMouseToFocusedWindow = settings.moveMouseToFocusedWindow
        workspaceBarEnabled = settings.workspaceBarEnabled
        preventSleepEnabled = settings.preventSleepEnabled
        quakeTerminalEnabled = settings.quakeTerminalEnabled
    }
}

@MainActor @Observable
final class Runtime {
    private static let maxTraceRecordCount = 128

    let settings: SettingsStore
    let platform: WMPlatform
    let workspaceManager: WorkspaceManager
    let hiddenBarController: HiddenBarController
    let controller: WMController
    private let effectExecutor: any EffectExecutor
    private(set) var snapshot: RuntimeSnapshot
    private(set) var recentTrace: [RuntimeTraceRecord] = []
    private var nextEventId: UInt64 = 1

    var state: WMState {
        snapshot.state
    }

    var stateSnapshot: WMSnapshot {
        snapshot.state
    }

    var refreshSnapshot: RefreshSnapshot {
        snapshot.state.refresh
    }

    var configuration: RuntimeConfiguration {
        snapshot.configuration
    }

    init(
        settings: SettingsStore,
        platform: WMPlatform = .shared,
        hiddenBarController: HiddenBarController? = nil,
        windowFocusOperations: WindowFocusOperations? = nil,
        effectExecutor: (any EffectExecutor)? = nil
    ) {
        self.settings = settings
        self.platform = platform
        let resolvedHiddenBarController = hiddenBarController ?? HiddenBarController(settings: settings)
        self.hiddenBarController = resolvedHiddenBarController
        let workspaceManager = WorkspaceManager(settings: settings)
        self.workspaceManager = workspaceManager
        controller = WMController(
            settings: settings,
            workspaceManager: workspaceManager,
            hiddenBarController: resolvedHiddenBarController,
            platform: platform,
            windowFocusOperations: windowFocusOperations ?? platform.windowFocusOperations
        )
        self.effectExecutor = effectExecutor ?? RuntimeEffectExecutor()
        var initialState = workspaceManager.reconcileSnapshot()
        initialState.refresh = .init()
        initialState.nextManagedRequestId = controller.focusBridge.nextManagedRequestId
        initialState.activeManagedRequest = controller.focusBridge.activeManagedRequest
        snapshot = RuntimeSnapshot(
            state: initialState,
            configuration: RuntimeConfiguration(settings: settings)
        )
        controller.runtime = self
    }

    func start() {
        applyCurrentConfiguration()
    }

    func applyCurrentConfiguration() {
        applyConfiguration(RuntimeConfiguration(settings: settings))
    }

    func applyConfiguration(_ configuration: RuntimeConfiguration) {
        snapshot.configuration = configuration
        controller.applyConfiguration(configuration)
        refreshSnapshotState()
        WMLog.info(.engine, "Applied runtime configuration: \(configuration.summary)")
        appendTrace(
            eventSummary: "configuration_applied",
            decisionSummary: nil,
            actionSummaries: [configuration.summary]
        )
    }

    func flushState() {
        workspaceManager.flushPersistedWindowRestoreCatalogNow()
        settings.flushNow()
    }

    @discardableResult
    func submit(_ event: WMEvent) -> RuntimeSubmitResult {
        switch event {
        case let .focusRequested(request):
            return .coordination(
                apply(
                    .focusRequested(request),
                    context: .focusRequest
                )
            )
        case let .activationObserved(observation):
            return .coordination(
                apply(
                    .activationObserved(observation),
                    context: .activationObserved(
                        observedAXRef: nil,
                        managedEntry: nil,
                        source: observation.source,
                        confirmRequest: true
                    )
                )
            )
        case let .refreshRequested(request):
            return .coordination(
                apply(
                    .refreshRequested(request),
                    context: .refresh
                )
            )
        case let .refreshCompleted(completion):
            return .coordination(
                apply(
                    .refreshCompleted(completion),
                    context: .refresh
                )
            )
        default:
            synchronizeManagedFocusBridge(for: event)

            let transaction = workspaceManager.recordEngineEvent(event)
            refreshSnapshotState()
            appendTrace(
                eventSummary: event.summary,
                decisionSummary: transaction.plan.summary,
                actionSummaries: transaction.plan.isEmpty ? [] : [transaction.plan.summary]
            )
            return .reconcile(transaction)
        }
    }

    func requestManagedFocus(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID
    ) -> CoordinationResult {
        apply(
            .focusRequested(
                .init(
                    token: token,
                    workspaceId: workspaceId
                )
            ),
            context: .focusRequest
        )
    }

    func observeActivation(
        _ observation: ManagedActivationObservation,
        observedAXRef: AXWindowRef?,
        managedEntry: WindowModel.Entry?,
        confirmRequest: Bool = true
    ) -> CoordinationResult {
        apply(
            .activationObserved(observation),
            context: .activationObserved(
                observedAXRef: observedAXRef,
                managedEntry: managedEntry,
                source: observation.source,
                confirmRequest: confirmRequest
            )
        )
    }

    func requestRefresh(
        _ request: RefreshRequestEvent
    ) -> CoordinationResult {
        apply(
            .refreshRequested(request),
            context: .refresh
        )
    }

    func completeRefresh(
        _ completion: RefreshCompletionEvent
    ) -> CoordinationResult {
        apply(
            .refreshCompleted(completion),
            context: .refresh
        )
    }

    func resetRefreshCoordination() {
        snapshot.state.refresh = .init()
        appendTrace(
            eventSummary: "refresh_reset",
            decisionSummary: nil,
            actionSummaries: []
        )
    }

    private func apply(
        _ event: WMEvent,
        context: RuntimeEffectContext
    ) -> CoordinationResult {
        synchronizeStateSnapshot()

        let result = CoordinationCore.step(
            snapshot: snapshot.state,
            event: event
        )
        snapshot.state = result.snapshot

        effectExecutor.execute(
            result,
            on: controller,
            context: context
        )

        refreshSnapshotState()
        appendTrace(
            eventSummary: String(describing: event),
            decisionSummary: String(describing: result.decision),
            actionSummaries: result.plan.actions.map { String(describing: $0) }
        )
        return result
    }

    private func synchronizeStateSnapshot() {
        snapshot.state = makeStateSnapshot(refresh: snapshot.state.refresh)
    }

    private func refreshSnapshotState() {
        snapshot.state = makeStateSnapshot(refresh: snapshot.state.refresh)
    }

    private func makeStateSnapshot(
        refresh: RefreshSnapshot
    ) -> WMSnapshot {
        var refreshedState = workspaceManager.reconcileSnapshot()
        refreshedState.refresh = refresh
        refreshedState.focus.nextManagedRequestId = controller.focusBridge.nextManagedRequestId
        refreshedState.focus.activeManagedRequest = controller.focusBridge.activeManagedRequest
        return refreshedState
    }

    private func synchronizeManagedFocusBridge(for event: WMEvent) {
        switch event {
        case let .windowRekeyed(from, to, _, _, _, _):
            controller.focusBridge.rekeyManagedRequest(from: from, to: to)
        case let .windowRemoved(token, workspaceId, _):
            _ = controller.focusBridge.cancelManagedRequest(
                matching: token,
                workspaceId: workspaceId
            )
            controller.focusBridge.discardPendingFocus(token)
            controller.focusBridge.clearFocusedTarget(matching: token)
        default:
            break
        }
    }

    private func appendTrace(
        eventSummary: String,
        decisionSummary: String?,
        actionSummaries: [String]
    ) {
        let record = RuntimeTraceRecord(
            eventId: nextEventId,
            timestamp: Date(),
            eventSummary: eventSummary,
            decisionSummary: decisionSummary,
            actionSummaries: actionSummaries,
            focusedToken: snapshot.state.focusSession.focusedToken,
            pendingFocusedToken: snapshot.state.focusSession.pendingManagedFocus.token,
            activeRefreshCycleId: snapshot.state.refresh.activeRefresh?.cycleId,
            pendingRefreshCycleId: snapshot.state.refresh.pendingRefresh?.cycleId
        )
        nextEventId &+= 1
        recentTrace.append(record)
        if recentTrace.count > Self.maxTraceRecordCount {
            recentTrace.removeFirst(recentTrace.count - Self.maxTraceRecordCount)
        }
    }
}

@MainActor
final class RuntimeStore {
    private let traceRecorder: EngineTraceRecorder
    private let nowProvider: () -> Date

    init(
        traceRecorder: EngineTraceRecorder,
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
    ) -> EngineTransaction {
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
    ) -> EngineTransaction {
        let invariantViolations = InvariantChecks.validate(snapshot: snapshot)
        var tracedPlan = plan
        if !invariantViolations.isEmpty {
            WMLog.error(
                .engine,
                "Invariant violations detected: \(invariantViolations.map(\.code).joined(separator: ","))"
            )
            tracedPlan.notes.append(contentsOf: invariantViolations.map(\.traceNote))
        }

        let txn = EngineTransaction(
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

@MainActor
final class RuntimeEffectExecutor: EffectExecutor {
    func execute(
        _ result: CoordinationResult,
        on controller: WMController,
        context: RuntimeEffectContext
    ) {
        switch context {
        case .focusRequest:
            controller.applyRuntimeFocusRequestResult(result)

        case let .activationObserved(observedAXRef, managedEntry, source, confirmRequest):
            controller.axEventHandler.applyActivationCoordinationResult(
                result,
                observedAXRef: observedAXRef,
                managedEntry: managedEntry,
                source: source,
                confirmRequest: confirmRequest
            )

        case .refresh:
            controller.layoutRefreshController.applyRuntimeRefreshResult(result)
        }
    }
}

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
