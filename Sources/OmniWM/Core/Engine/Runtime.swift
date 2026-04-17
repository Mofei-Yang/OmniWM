import Foundation
import Observation

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
        platform: WMPlatform = .live,
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

            let transaction = workspaceManager.recordReconcileEvent(event)
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
    ) -> OrchestrationResult {
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
    ) -> OrchestrationResult {
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
    ) -> OrchestrationResult {
        apply(
            .refreshRequested(request),
            context: .refresh
        )
    }

    func completeRefresh(
        _ completion: RefreshCompletionEvent
    ) -> OrchestrationResult {
        apply(
            .refreshCompleted(completion),
            context: .refresh
        )
    }

    func resetRefreshOrchestration() {
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
    ) -> OrchestrationResult {
        synchronizeStateSnapshot()

        let result = OrchestrationCore.step(
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
