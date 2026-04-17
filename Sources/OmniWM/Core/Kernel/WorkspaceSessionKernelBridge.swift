import COmniWMKernels
import Foundation

func workspaceSessionKernelOutputValidationFailureReason(
    status: Int32,
    rawOutput: omniwm_workspace_session_output,
    monitorCapacity: Int,
    workspaceProjectionCapacity: Int,
    disconnectedCacheCapacity: Int
) -> String? {
    guard status == OMNIWM_KERNELS_STATUS_OK else {
        return "omniwm_workspace_session_plan returned \(status)"
    }
    guard rawOutput.monitor_result_count <= monitorCapacity else {
        return "omniwm_workspace_session_plan reported \(rawOutput.monitor_result_count) monitor results for capacity \(monitorCapacity)"
    }
    guard rawOutput.workspace_projection_count <= workspaceProjectionCapacity else {
        return "omniwm_workspace_session_plan reported \(rawOutput.workspace_projection_count) workspace projections for capacity \(workspaceProjectionCapacity)"
    }
    guard rawOutput.disconnected_cache_result_count <= disconnectedCacheCapacity else {
        return "omniwm_workspace_session_plan reported \(rawOutput.disconnected_cache_result_count) disconnected cache results for capacity \(disconnectedCacheCapacity)"
    }
    return nil
}

// Error-conforming so we can move callers from `Plan?` to `throws` later without re-typing the cause.
enum WorkspaceSessionKernelError: Error, Equatable {
    case invocationFailed(reason: String)

    var reason: String {
        switch self {
        case .invocationFailed(let reason): return reason
        }
    }
}

enum WorkspaceSessionKernelFallback {
    /// Single reporting choke point for kernel invocation failures.
    ///
    /// Each caller still chooses its local degradation (cache, nil, no-op)
    /// because their return shapes differ — but every failure flows through
    /// here so logging, telemetry, and DEBUG assertions live in one place
    /// instead of being scattered across call sites.
    static func report(_ error: WorkspaceSessionKernelError, operation: StaticString) {
        let message = "[WorkspaceSessionKernel] \(operation) failed: \(error.reason)"
        // fputs covers release builds; assertionFailure covers debug.
        fputs("\(message)\n", stderr)
        assertionFailure(message)
    }
}

@MainActor
enum WorkspaceSessionKernel {
    enum Outcome {
        case noop
        case apply
        case invalidTarget
        case invalidPatch

        init(kernelRawValue: UInt32) {
            switch kernelRawValue {
            case UInt32(OMNIWM_WORKSPACE_SESSION_OUTCOME_NOOP):
                self = .noop
            case UInt32(OMNIWM_WORKSPACE_SESSION_OUTCOME_APPLY):
                self = .apply
            case UInt32(OMNIWM_WORKSPACE_SESSION_OUTCOME_INVALID_TARGET):
                self = .invalidTarget
            case UInt32(OMNIWM_WORKSPACE_SESSION_OUTCOME_INVALID_PATCH):
                self = .invalidPatch
            default:
                KernelContract.unknownRawValue(kernelRawValue, label: "WorkspaceSessionKernel.Outcome")
            }
        }
    }

    enum PatchViewportAction {
        case none
        case apply
        case preserveCurrent

        init(kernelRawValue: UInt32) {
            switch kernelRawValue {
            case UInt32(OMNIWM_WORKSPACE_SESSION_PATCH_VIEWPORT_NONE):
                self = .none
            case UInt32(OMNIWM_WORKSPACE_SESSION_PATCH_VIEWPORT_APPLY):
                self = .apply
            case UInt32(OMNIWM_WORKSPACE_SESSION_PATCH_VIEWPORT_PRESERVE_CURRENT):
                self = .preserveCurrent
            default:
                KernelContract.unknownRawValue(kernelRawValue, label: "WorkspaceSessionKernel.PatchViewportAction")
            }
        }
    }

    enum FocusClearAction {
        case none
        case pending
        case pendingAndConfirmed

        init(kernelRawValue: UInt32) {
            switch kernelRawValue {
            case UInt32(OMNIWM_WORKSPACE_SESSION_FOCUS_CLEAR_NONE):
                self = .none
            case UInt32(OMNIWM_WORKSPACE_SESSION_FOCUS_CLEAR_PENDING):
                self = .pending
            case UInt32(OMNIWM_WORKSPACE_SESSION_FOCUS_CLEAR_PENDING_AND_CONFIRMED):
                self = .pendingAndConfirmed
            default:
                KernelContract.unknownRawValue(kernelRawValue, label: "WorkspaceSessionKernel.FocusClearAction")
            }
        }
    }

    struct MonitorState {
        var monitorId: Monitor.ID
        var visibleWorkspaceId: WorkspaceDescriptor.ID?
        var previousVisibleWorkspaceId: WorkspaceDescriptor.ID?
        var resolvedActiveWorkspaceId: WorkspaceDescriptor.ID?
    }

    struct WorkspaceProjectionRecord {
        var workspaceId: WorkspaceDescriptor.ID
        var projectedMonitorId: Monitor.ID?
        var homeMonitorId: Monitor.ID?
        var effectiveMonitorId: Monitor.ID?
    }

    struct Plan {
        var outcome: Outcome
        var patchViewportAction: PatchViewportAction
        var focusClearAction: FocusClearAction
        var interactionMonitorId: Monitor.ID?
        var previousInteractionMonitorId: Monitor.ID?
        var resolvedFocusToken: WindowToken?
        var monitorStates: [MonitorState]
        var workspaceProjections: [WorkspaceProjectionRecord]
        var shouldRememberFocus: Bool
    }

    private struct FocusSnapshot {
        var focusedWorkspaceId: WorkspaceDescriptor.ID?
        var pendingTiledToken: WindowToken?
        var pendingTiledWorkspaceId: WorkspaceDescriptor.ID?
        var confirmedTiledToken: WindowToken?
        var confirmedTiledWorkspaceId: WorkspaceDescriptor.ID?
        var confirmedFloatingToken: WindowToken?
        var confirmedFloatingWorkspaceId: WorkspaceDescriptor.ID?
    }

    private struct AssignmentSnapshot {
        var rawAssignmentKind: UInt32
        var specificDisplayId: UInt32?
        var specificDisplayName: String?
    }

    private struct PreviousMonitorSnapshot {
        var monitor: Monitor
        var visibleWorkspaceId: WorkspaceDescriptor.ID?
        var previousVisibleWorkspaceId: WorkspaceDescriptor.ID?
    }

    private struct DisconnectedCacheEntrySnapshot {
        var restoreKey: MonitorRestoreKey
        var workspaceId: WorkspaceDescriptor.ID
    }

    private struct DisconnectedCacheResultRecord {
        var sourceKind: UInt32
        var sourceIndex: Int
        var workspaceId: WorkspaceDescriptor.ID
    }

    private struct InvocationResult {
        var plan: Plan
        var disconnectedCacheResults: [DisconnectedCacheResultRecord]
        var refreshRestoreIntents: Bool
    }

    private struct KernelStringTable {
        private(set) var bytes = ContiguousArray<UInt8>()

        mutating func append(_ string: String?) -> (ref: omniwm_restore_string_ref, hasValue: UInt8) {
            guard let string else {
                return (omniwm_restore_string_ref(offset: 0, length: 0), 0)
            }

            let utf8 = Array(string.utf8)
            let offset = bytes.count
            bytes.append(contentsOf: utf8)
            return (
                omniwm_restore_string_ref(offset: offset, length: utf8.count),
                1
            )
        }
    }

    static func project(
        manager: WorkspaceManager,
        monitors: [Monitor]
    ) -> Plan? {
        invoke(
            manager: manager,
            monitors: monitors,
            operation: UInt32(OMNIWM_WORKSPACE_SESSION_OPERATION_PROJECT)
        )?.plan
    }

    static func reconcileVisible(
        manager: WorkspaceManager
    ) -> Plan? {
        invoke(
            manager: manager,
            monitors: manager.monitors,
            operation: UInt32(OMNIWM_WORKSPACE_SESSION_OPERATION_RECONCILE_VISIBLE)
        )?.plan
    }

    static func activateWorkspace(
        manager: WorkspaceManager,
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID,
        updateInteractionMonitor: Bool
    ) -> Plan? {
        invoke(
            manager: manager,
            monitors: manager.monitors,
            operation: UInt32(OMNIWM_WORKSPACE_SESSION_OPERATION_ACTIVATE_WORKSPACE),
            workspaceId: workspaceId,
            monitorId: monitorId,
            updateInteractionMonitor: updateInteractionMonitor,
            preservePreviousInteractionMonitor: true
        )?.plan
    }

    static func setInteractionMonitor(
        manager: WorkspaceManager,
        monitorId: Monitor.ID?,
        preservePrevious: Bool
    ) -> Plan? {
        invoke(
            manager: manager,
            monitors: manager.monitors,
            operation: UInt32(OMNIWM_WORKSPACE_SESSION_OPERATION_SET_INTERACTION_MONITOR),
            monitorId: monitorId,
            preservePreviousInteractionMonitor: preservePrevious
        )?.plan
    }

    static func resolvePreferredFocus(
        manager: WorkspaceManager,
        workspaceId: WorkspaceDescriptor.ID
    ) -> Plan? {
        invoke(
            manager: manager,
            monitors: [],
            operation: UInt32(OMNIWM_WORKSPACE_SESSION_OPERATION_RESOLVE_PREFERRED_FOCUS),
            workspaceId: workspaceId
        )?.plan
    }

    static func resolveWorkspaceFocus(
        manager: WorkspaceManager,
        workspaceId: WorkspaceDescriptor.ID
    ) -> Plan? {
        invoke(
            manager: manager,
            monitors: [],
            operation: UInt32(OMNIWM_WORKSPACE_SESSION_OPERATION_RESOLVE_WORKSPACE_FOCUS),
            workspaceId: workspaceId
        )?.plan
    }

    static func applySessionPatch(
        manager: WorkspaceManager,
        patch: WorkspaceSessionPatch
    ) -> Plan? {
        invoke(
            manager: manager,
            monitors: [],
            operation: UInt32(OMNIWM_WORKSPACE_SESSION_OPERATION_APPLY_SESSION_PATCH),
            workspaceId: patch.workspaceId,
            patch: patch
        )?.plan
    }

    static func reconcileTopology(
        manager: WorkspaceManager,
        newMonitors: [Monitor]
    ) -> TopologyTransitionPlan? {
        let previousMonitors = previousMonitorSnapshots(manager: manager)
        let disconnectedCacheEntries = disconnectedCacheEntries(manager: manager)
        guard let result = invoke(
            manager: manager,
            monitors: newMonitors,
            previousMonitors: previousMonitors,
            operation: UInt32(OMNIWM_WORKSPACE_SESSION_OPERATION_RECONCILE_TOPOLOGY),
            disconnectedCacheEntries: disconnectedCacheEntries
        ) else {
            return nil
        }

        var disconnectedCache: [MonitorRestoreKey: WorkspaceDescriptor.ID] = [:]
        disconnectedCache.reserveCapacity(result.disconnectedCacheResults.count)
        for entry in result.disconnectedCacheResults {
            let restoreKey: MonitorRestoreKey
            switch entry.sourceKind {
            case UInt32(OMNIWM_RESTORE_CACHE_SOURCE_EXISTING):
                guard disconnectedCacheEntries.indices.contains(entry.sourceIndex) else { continue }
                restoreKey = disconnectedCacheEntries[entry.sourceIndex].restoreKey
            case UInt32(OMNIWM_RESTORE_CACHE_SOURCE_REMOVED_MONITOR):
                guard previousMonitors.indices.contains(entry.sourceIndex) else { continue }
                restoreKey = MonitorRestoreKey(monitor: previousMonitors[entry.sourceIndex].monitor)
            default:
                KernelContract.unknownRawValue(entry.sourceKind, label: "OMNIWM_RESTORE_CACHE_SOURCE")
            }
            disconnectedCache[restoreKey] = entry.workspaceId
        }

        return TopologyTransitionPlan(
            previousMonitors: previousMonitors.map(\.monitor),
            newMonitors: newMonitors,
            monitorStates: result.plan.monitorStates.map {
                TopologyMonitorSessionState(
                    monitorId: $0.monitorId,
                    visibleWorkspaceId: $0.visibleWorkspaceId,
                    previousVisibleWorkspaceId: $0.previousVisibleWorkspaceId
                )
            },
            workspaceProjections: result.plan.workspaceProjections.map {
                TopologyWorkspaceProjectionRecord(
                    workspaceId: $0.workspaceId,
                    projectedMonitorId: $0.projectedMonitorId,
                    homeMonitorId: $0.homeMonitorId,
                    effectiveMonitorId: $0.effectiveMonitorId
                )
            },
            disconnectedVisibleWorkspaceCache: disconnectedCache,
            interactionMonitorId: result.plan.interactionMonitorId,
            previousInteractionMonitorId: result.plan.previousInteractionMonitorId,
            refreshRestoreIntents: result.refreshRestoreIntents
        )
    }

    private static func invoke(
        manager: WorkspaceManager,
        monitors: [Monitor],
        previousMonitors: [PreviousMonitorSnapshot] = [],
        operation: UInt32,
        workspaceId: WorkspaceDescriptor.ID? = nil,
        monitorId: Monitor.ID? = nil,
        updateInteractionMonitor: Bool = false,
        preservePreviousInteractionMonitor: Bool = false,
        disconnectedCacheEntries: [DisconnectedCacheEntrySnapshot] = [],
        patch: WorkspaceSessionPatch? = nil
    ) -> InvocationResult? {
        let focusSnapshot = focusSnapshot(manager: manager)
        let sortedWorkspaces = manager.workspaceStore.sortedWorkspaces()

        var stringTable = KernelStringTable()
        var rawMonitors = ContiguousArray<omniwm_workspace_session_monitor>()
        rawMonitors.reserveCapacity(monitors.count)
        for monitor in monitors {
            let session = manager.sessionState.monitorSessions[monitor.id]
            let encodedName = stringTable.append(monitor.name)
            rawMonitors.append(
                omniwm_workspace_session_monitor(
                    monitor_id: monitor.id.displayId,
                    frame_min_x: monitor.frame.minX,
                    frame_max_y: monitor.frame.maxY,
                    frame_width: monitor.frame.width,
                    frame_height: monitor.frame.height,
                    anchor_x: monitor.workspaceAnchorPoint.x,
                    anchor_y: monitor.workspaceAnchorPoint.y,
                    visible_workspace_id: session?.visibleWorkspaceId.map(encode(uuid:)) ?? zeroUUID(),
                    previous_visible_workspace_id: session?.previousVisibleWorkspaceId
                        .map(encode(uuid:)) ?? zeroUUID(),
                    name: encodedName.ref,
                    is_main: monitor.isMain ? 1 : 0,
                    has_visible_workspace_id: session?.visibleWorkspaceId == nil ? 0 : 1,
                    has_previous_visible_workspace_id: session?.previousVisibleWorkspaceId == nil ? 0 : 1,
                    has_name: encodedName.hasValue
                )
            )
        }

        var rawPreviousMonitors = ContiguousArray<omniwm_workspace_session_previous_monitor>()
        rawPreviousMonitors.reserveCapacity(previousMonitors.count)
        for previousMonitor in previousMonitors {
            let encodedName = stringTable.append(previousMonitor.monitor.name)
            rawPreviousMonitors.append(
                omniwm_workspace_session_previous_monitor(
                    monitor_id: previousMonitor.monitor.id.displayId,
                    frame_min_x: previousMonitor.monitor.frame.minX,
                    frame_max_y: previousMonitor.monitor.frame.maxY,
                    frame_width: previousMonitor.monitor.frame.width,
                    frame_height: previousMonitor.monitor.frame.height,
                    anchor_x: previousMonitor.monitor.workspaceAnchorPoint.x,
                    anchor_y: previousMonitor.monitor.workspaceAnchorPoint.y,
                    visible_workspace_id: previousMonitor.visibleWorkspaceId.map(encode(uuid:)) ?? zeroUUID(),
                    previous_visible_workspace_id: previousMonitor.previousVisibleWorkspaceId
                        .map(encode(uuid:)) ?? zeroUUID(),
                    name: encodedName.ref,
                    has_visible_workspace_id: previousMonitor.visibleWorkspaceId == nil ? 0 : 1,
                    has_previous_visible_workspace_id: previousMonitor.previousVisibleWorkspaceId == nil ? 0 : 1,
                    has_name: encodedName.hasValue
                )
            )
        }

        var rawWorkspaces = ContiguousArray<omniwm_workspace_session_workspace>()
        rawWorkspaces.reserveCapacity(sortedWorkspaces.count)
        for workspace in sortedWorkspaces {
            let assignment = assignmentSnapshot(manager: manager, workspace: workspace)
            let assignmentName = stringTable.append(assignment.specificDisplayName)
            let assignedAnchorPoint = workspace.assignedMonitorPoint
                ?? manager.monitorIdShowingWorkspace(workspace.id)
                .flatMap { manager.monitor(byId: $0)?.workspaceAnchorPoint }
            rawWorkspaces.append(
                omniwm_workspace_session_workspace(
                    workspace_id: encode(uuid: workspace.id),
                    assigned_anchor_point: encode(point: assignedAnchorPoint ?? .zero),
                    assignment_kind: assignment.rawAssignmentKind,
                    specific_display_id: assignment.specificDisplayId ?? 0,
                    specific_display_name: assignmentName.ref,
                    remembered_tiled_focus_token: manager.lastFocusedToken(in: workspace.id)
                        .map(encode(token:)) ?? zeroToken(),
                    remembered_floating_focus_token: manager.lastFloatingFocusedToken(in: workspace.id)
                        .map(encode(token:)) ?? zeroToken(),
                    has_assigned_anchor_point: assignedAnchorPoint == nil ? 0 : 1,
                    has_specific_display_id: assignment.specificDisplayId == nil ? 0 : 1,
                    has_specific_display_name: assignmentName.hasValue,
                    has_remembered_tiled_focus_token: manager.lastFocusedToken(in: workspace.id) == nil ? 0 : 1,
                    has_remembered_floating_focus_token: manager
                        .lastFloatingFocusedToken(in: workspace.id) == nil ? 0 : 1
                )
            )
        }

        var rawWindowCandidates = ContiguousArray<omniwm_workspace_session_window_candidate>()
        for workspace in sortedWorkspaces {
            appendWindowCandidates(
                manager.tiledEntries(in: workspace.id),
                workspaceId: workspace.id,
                rawMode: UInt32(OMNIWM_WORKSPACE_SESSION_WINDOW_MODE_TILING),
                into: &rawWindowCandidates
            )
            appendWindowCandidates(
                manager.floatingEntries(in: workspace.id),
                workspaceId: workspace.id,
                rawMode: UInt32(OMNIWM_WORKSPACE_SESSION_WINDOW_MODE_FLOATING),
                into: &rawWindowCandidates
            )
        }

        var rawDisconnectedCacheEntries = ContiguousArray<omniwm_workspace_session_disconnected_cache_entry>()
        rawDisconnectedCacheEntries.reserveCapacity(disconnectedCacheEntries.count)
        for entry in disconnectedCacheEntries {
            let encodedName = stringTable.append(entry.restoreKey.name)
            rawDisconnectedCacheEntries.append(
                omniwm_workspace_session_disconnected_cache_entry(
                    workspace_id: encode(uuid: entry.workspaceId),
                    display_id: entry.restoreKey.displayId,
                    anchor_x: entry.restoreKey.anchorPoint.x,
                    anchor_y: entry.restoreKey.anchorPoint.y,
                    frame_width: entry.restoreKey.frameSize.width,
                    frame_height: entry.restoreKey.frameSize.height,
                    name: encodedName.ref,
                    has_name: encodedName.hasValue
                )
            )
        }

        let currentViewport = rawViewportSnapshot(
            workspaceId.flatMap { manager.sessionState.workspaceSessions[$0]?.niriViewportState }
        )
        let patchViewport = rawViewportSnapshot(patch?.viewportState)
        var rawInput = omniwm_workspace_session_input(
            operation: operation,
            workspace_id: workspaceId.map(encode(uuid:)) ?? zeroUUID(),
            monitor_id: monitorId?.displayId ?? 0,
            focused_workspace_id: focusSnapshot.focusedWorkspaceId.map(encode(uuid:)) ?? zeroUUID(),
            pending_tiled_workspace_id: focusSnapshot.pendingTiledWorkspaceId.map(encode(uuid:)) ?? zeroUUID(),
            confirmed_tiled_workspace_id: focusSnapshot.confirmedTiledWorkspaceId.map(encode(uuid:)) ?? zeroUUID(),
            confirmed_floating_workspace_id: focusSnapshot.confirmedFloatingWorkspaceId
                .map(encode(uuid:)) ?? zeroUUID(),
            pending_tiled_focus_token: focusSnapshot.pendingTiledToken.map(encode(token:)) ?? zeroToken(),
            confirmed_tiled_focus_token: focusSnapshot.confirmedTiledToken.map(encode(token:)) ?? zeroToken(),
            confirmed_floating_focus_token: focusSnapshot.confirmedFloatingToken.map(encode(token:)) ?? zeroToken(),
            remembered_focus_token: patch?.rememberedFocusToken.map(encode(token:)) ?? zeroToken(),
            interaction_monitor_id: manager.sessionState.interactionMonitorId?.displayId ?? 0,
            previous_interaction_monitor_id: manager.sessionState.previousInteractionMonitorId?.displayId ?? 0,
            current_viewport_kind: currentViewport.kind,
            current_viewport_active_column_index: currentViewport.activeColumnIndex,
            patch_viewport_kind: patchViewport.kind,
            patch_viewport_active_column_index: patchViewport.activeColumnIndex,
            has_workspace_id: workspaceId == nil ? 0 : 1,
            has_monitor_id: monitorId == nil ? 0 : 1,
            has_focused_workspace_id: focusSnapshot.focusedWorkspaceId == nil ? 0 : 1,
            has_pending_tiled_workspace_id: focusSnapshot.pendingTiledWorkspaceId == nil ? 0 : 1,
            has_confirmed_tiled_workspace_id: focusSnapshot.confirmedTiledWorkspaceId == nil ? 0 : 1,
            has_confirmed_floating_workspace_id: focusSnapshot.confirmedFloatingWorkspaceId == nil ? 0 : 1,
            has_pending_tiled_focus_token: focusSnapshot.pendingTiledToken == nil ? 0 : 1,
            has_confirmed_tiled_focus_token: focusSnapshot.confirmedTiledToken == nil ? 0 : 1,
            has_confirmed_floating_focus_token: focusSnapshot.confirmedFloatingToken == nil ? 0 : 1,
            has_remembered_focus_token: patch?.rememberedFocusToken == nil ? 0 : 1,
            has_interaction_monitor_id: manager.sessionState.interactionMonitorId == nil ? 0 : 1,
            has_previous_interaction_monitor_id: manager.sessionState.previousInteractionMonitorId == nil ? 0 : 1,
            has_current_viewport_state: currentViewport.hasState ? 1 : 0,
            has_patch_viewport_state: patchViewport.hasState ? 1 : 0,
            should_update_interaction_monitor: updateInteractionMonitor ? 1 : 0,
            preserve_previous_interaction_monitor: preservePreviousInteractionMonitor ? 1 : 0
        )

        var rawMonitorResults = ContiguousArray(
            repeating: omniwm_workspace_session_monitor_result(
                monitor_id: 0,
                visible_workspace_id: zeroUUID(),
                previous_visible_workspace_id: zeroUUID(),
                resolved_active_workspace_id: zeroUUID(),
                has_visible_workspace_id: 0,
                has_previous_visible_workspace_id: 0,
                has_resolved_active_workspace_id: 0
            ),
            count: monitors.count
        )
        var rawWorkspaceProjections = ContiguousArray(
            repeating: omniwm_workspace_session_workspace_projection(
                workspace_id: zeroUUID(),
                projected_monitor_id: 0,
                home_monitor_id: 0,
                effective_monitor_id: 0,
                has_projected_monitor_id: 0,
                has_home_monitor_id: 0,
                has_effective_monitor_id: 0
            ),
            count: manager.workspaces.count
        )
        var rawDisconnectedCacheResults = ContiguousArray(
            repeating: omniwm_workspace_session_disconnected_cache_result(
                source_kind: 0,
                source_index: 0,
                workspace_id: zeroUUID()
            ),
            count: disconnectedCacheEntries.count + previousMonitors.count
        )
        var rawOutput = omniwm_workspace_session_output(
            outcome: 0,
            patch_viewport_action: 0,
            focus_clear_action: 0,
            interaction_monitor_id: 0,
            previous_interaction_monitor_id: 0,
            resolved_focus_token: zeroToken(),
            monitor_results: nil,
            monitor_result_capacity: rawMonitorResults.count,
            monitor_result_count: 0,
            workspace_projections: nil,
            workspace_projection_capacity: rawWorkspaceProjections.count,
            workspace_projection_count: 0,
            disconnected_cache_results: nil,
            disconnected_cache_result_capacity: rawDisconnectedCacheResults.count,
            disconnected_cache_result_count: 0,
            has_interaction_monitor_id: 0,
            has_previous_interaction_monitor_id: 0,
            has_resolved_focus_token: 0,
            should_remember_focus: 0,
            refresh_restore_intents: 0
        )

        let status = rawMonitors.withUnsafeBufferPointer { monitorBuffer in
            rawPreviousMonitors.withUnsafeBufferPointer { previousMonitorBuffer in
                rawWorkspaces.withUnsafeBufferPointer { workspaceBuffer in
                    rawWindowCandidates.withUnsafeBufferPointer { candidateBuffer in
                        rawDisconnectedCacheEntries.withUnsafeBufferPointer { disconnectedCacheBuffer in
                            stringTable.bytes.withUnsafeBufferPointer { stringBuffer in
                                rawMonitorResults.withUnsafeMutableBufferPointer { monitorResultBuffer in
                                    rawWorkspaceProjections
                                        .withUnsafeMutableBufferPointer { workspaceProjectionBuffer in
                                            rawDisconnectedCacheResults
                                                .withUnsafeMutableBufferPointer { disconnectedCacheResultBuffer in
                                                    rawOutput.monitor_results = monitorResultBuffer.baseAddress
                                                    rawOutput.workspace_projections = workspaceProjectionBuffer
                                                        .baseAddress
                                                    rawOutput
                                                        .disconnected_cache_results =
                                                        disconnectedCacheResultBuffer
                                                            .baseAddress
                                                    return withUnsafeMutablePointer(to: &rawInput) { inputPointer in
                                                        withUnsafeMutablePointer(to: &rawOutput) { outputPointer in
                                                            omniwm_workspace_session_plan(
                                                                inputPointer,
                                                                monitorBuffer.baseAddress,
                                                                monitorBuffer.count,
                                                                previousMonitorBuffer.baseAddress,
                                                                previousMonitorBuffer.count,
                                                                workspaceBuffer.baseAddress,
                                                                workspaceBuffer.count,
                                                                candidateBuffer.baseAddress,
                                                                candidateBuffer.count,
                                                                disconnectedCacheBuffer.baseAddress,
                                                                disconnectedCacheBuffer.count,
                                                                stringBuffer.baseAddress,
                                                                stringBuffer.count,
                                                                outputPointer
                                                            )
                                                        }
                                                    }
                                                }
                                        }
                                }
                            }
                        }
                    }
                }
            }
        }

        if let failureReason = workspaceSessionKernelOutputValidationFailureReason(
            status: status,
            rawOutput: rawOutput,
            monitorCapacity: rawMonitorResults.count,
            workspaceProjectionCapacity: rawWorkspaceProjections.count,
            disconnectedCacheCapacity: rawDisconnectedCacheResults.count
        ) {
            WorkspaceSessionKernelFallback.report(
                .invocationFailed(reason: failureReason),
                operation: "WorkspaceSessionKernel.invoke"
            )
            return nil
        }

        return decodeInvocationResult(
            rawOutput: rawOutput,
            rawMonitorResults: rawMonitorResults,
            rawWorkspaceProjections: rawWorkspaceProjections,
            rawDisconnectedCacheResults: rawDisconnectedCacheResults
        )
    }

    private static func decodeInvocationResult(
        rawOutput: omniwm_workspace_session_output,
        rawMonitorResults: ContiguousArray<omniwm_workspace_session_monitor_result>,
        rawWorkspaceProjections: ContiguousArray<omniwm_workspace_session_workspace_projection>,
        rawDisconnectedCacheResults: ContiguousArray<omniwm_workspace_session_disconnected_cache_result>
    ) -> InvocationResult {
        InvocationResult(
            plan: Plan(
                outcome: Outcome(kernelRawValue: rawOutput.outcome),
                patchViewportAction: PatchViewportAction(kernelRawValue: rawOutput.patch_viewport_action),
                focusClearAction: FocusClearAction(kernelRawValue: rawOutput.focus_clear_action),
                interactionMonitorId: rawOutput.has_interaction_monitor_id == 0
                    ? nil
                    : Monitor.ID(displayId: rawOutput.interaction_monitor_id),
                previousInteractionMonitorId: rawOutput.has_previous_interaction_monitor_id == 0
                    ? nil
                    : Monitor.ID(displayId: rawOutput.previous_interaction_monitor_id),
                resolvedFocusToken: rawOutput.has_resolved_focus_token == 0
                    ? nil
                    : decode(token: rawOutput.resolved_focus_token),
                monitorStates: Array(rawMonitorResults.prefix(rawOutput.monitor_result_count)).map {
                    MonitorState(
                        monitorId: Monitor.ID(displayId: $0.monitor_id),
                        visibleWorkspaceId: $0
                            .has_visible_workspace_id == 0 ? nil : decode(uuid: $0.visible_workspace_id),
                        previousVisibleWorkspaceId: $0.has_previous_visible_workspace_id == 0
                            ? nil
                            : decode(uuid: $0.previous_visible_workspace_id),
                        resolvedActiveWorkspaceId: $0.has_resolved_active_workspace_id == 0
                            ? nil
                            : decode(uuid: $0.resolved_active_workspace_id)
                    )
                },
                workspaceProjections: Array(rawWorkspaceProjections.prefix(rawOutput.workspace_projection_count))
                    .map {
                        WorkspaceProjectionRecord(
                            workspaceId: decode(uuid: $0.workspace_id),
                            projectedMonitorId: $0.has_projected_monitor_id == 0 ? nil : Monitor
                                .ID(displayId: $0.projected_monitor_id),
                            homeMonitorId: $0.has_home_monitor_id == 0 ? nil : Monitor
                                .ID(displayId: $0.home_monitor_id),
                            effectiveMonitorId: $0.has_effective_monitor_id == 0 ? nil : Monitor
                                .ID(displayId: $0.effective_monitor_id)
                        )
                    },
                shouldRememberFocus: rawOutput.should_remember_focus != 0
            ),
            disconnectedCacheResults: Array(rawDisconnectedCacheResults
                .prefix(rawOutput.disconnected_cache_result_count)).map {
                DisconnectedCacheResultRecord(
                    sourceKind: $0.source_kind,
                    sourceIndex: Int($0.source_index),
                    workspaceId: decode(uuid: $0.workspace_id)
                )
            },
            refreshRestoreIntents: rawOutput.refresh_restore_intents != 0
        )
    }

    private static func previousMonitorSnapshots(
        manager: WorkspaceManager
    ) -> [PreviousMonitorSnapshot] {
        manager.monitors.map { monitor in
            let session = manager.sessionState.monitorSessions[monitor.id]
            return PreviousMonitorSnapshot(
                monitor: monitor,
                visibleWorkspaceId: session?.visibleWorkspaceId,
                previousVisibleWorkspaceId: session?.previousVisibleWorkspaceId
            )
        }
    }

    private static func disconnectedCacheEntries(
        manager: WorkspaceManager
    ) -> [DisconnectedCacheEntrySnapshot] {
        manager.workspaceStore.disconnectedVisibleWorkspaceCache.map {
            DisconnectedCacheEntrySnapshot(
                restoreKey: $0.key,
                workspaceId: $0.value
            )
        }
        .sorted { lhs, rhs in
            if lhs.restoreKey.displayId != rhs.restoreKey.displayId {
                return lhs.restoreKey.displayId < rhs.restoreKey.displayId
            }
            if lhs.restoreKey.name != rhs.restoreKey.name {
                return lhs.restoreKey.name < rhs.restoreKey.name
            }
            if lhs.restoreKey.anchorPoint.x != rhs.restoreKey.anchorPoint.x {
                return lhs.restoreKey.anchorPoint.x < rhs.restoreKey.anchorPoint.x
            }
            if lhs.restoreKey.anchorPoint.y != rhs.restoreKey.anchorPoint.y {
                return lhs.restoreKey.anchorPoint.y < rhs.restoreKey.anchorPoint.y
            }
            if lhs.restoreKey.frameSize.width != rhs.restoreKey.frameSize.width {
                return lhs.restoreKey.frameSize.width < rhs.restoreKey.frameSize.width
            }
            if lhs.restoreKey.frameSize.height != rhs.restoreKey.frameSize.height {
                return lhs.restoreKey.frameSize.height < rhs.restoreKey.frameSize.height
            }
            return lhs.workspaceId.uuidString < rhs.workspaceId.uuidString
        }
    }

    private static func focusSnapshot(
        manager: WorkspaceManager
    ) -> FocusSnapshot {
        let pendingTiled: (WindowToken, WorkspaceDescriptor.ID)? = if let token = manager.pendingFocusedToken,
                                                                      let workspaceId = manager
                                                                      .pendingFocusedWorkspaceId
        {
            (token, workspaceId)
        } else {
            nil
        }

        let confirmedManagedFocus: (
            WindowToken,
            WorkspaceDescriptor.ID,
            TrackedWindowMode
        )? = if let token = manager.focusedToken,
                let entry = manager.entry(for: token)
        {
            (token, entry.workspaceId, entry.mode)
        } else {
            nil
        }

        let confirmedTiledToken: WindowToken?
        let confirmedTiledWorkspaceId: WorkspaceDescriptor.ID?
        let confirmedFloatingToken: WindowToken?
        let confirmedFloatingWorkspaceId: WorkspaceDescriptor.ID?
        if let confirmedManagedFocus {
            switch confirmedManagedFocus.2 {
            case .tiling:
                confirmedTiledToken = confirmedManagedFocus.0
                confirmedTiledWorkspaceId = confirmedManagedFocus.1
                confirmedFloatingToken = nil
                confirmedFloatingWorkspaceId = nil
            case .floating:
                confirmedTiledToken = nil
                confirmedTiledWorkspaceId = nil
                confirmedFloatingToken = confirmedManagedFocus.0
                confirmedFloatingWorkspaceId = confirmedManagedFocus.1
            }
        } else {
            confirmedTiledToken = nil
            confirmedTiledWorkspaceId = nil
            confirmedFloatingToken = nil
            confirmedFloatingWorkspaceId = nil
        }

        return FocusSnapshot(
            focusedWorkspaceId: manager.focusedToken.flatMap { manager.entry(for: $0)?.workspaceId },
            pendingTiledToken: pendingTiled?.0,
            pendingTiledWorkspaceId: pendingTiled?.1,
            confirmedTiledToken: confirmedTiledToken,
            confirmedTiledWorkspaceId: confirmedTiledWorkspaceId,
            confirmedFloatingToken: confirmedFloatingToken,
            confirmedFloatingWorkspaceId: confirmedFloatingWorkspaceId
        )
    }

    private static func assignmentSnapshot(
        manager: WorkspaceManager,
        workspace: WorkspaceDescriptor
    ) -> AssignmentSnapshot {
        guard let config = manager.settings.workspaceConfigurations.first(where: { $0.name == workspace.name })
        else {
            return AssignmentSnapshot(rawAssignmentKind: UInt32(OMNIWM_WORKSPACE_SESSION_ASSIGNMENT_UNCONFIGURED))
        }

        switch config.monitorAssignment {
        case .main:
            return AssignmentSnapshot(rawAssignmentKind: UInt32(OMNIWM_WORKSPACE_SESSION_ASSIGNMENT_MAIN))
        case .secondary:
            return AssignmentSnapshot(rawAssignmentKind: UInt32(OMNIWM_WORKSPACE_SESSION_ASSIGNMENT_SECONDARY))
        case let .specificDisplay(output):
            return AssignmentSnapshot(
                rawAssignmentKind: UInt32(OMNIWM_WORKSPACE_SESSION_ASSIGNMENT_SPECIFIC_DISPLAY),
                specificDisplayId: output.displayId,
                specificDisplayName: output.name
            )
        }
    }

    private static func rawViewportSnapshot(
        _ state: ViewportState?
    ) -> (kind: UInt32, activeColumnIndex: Int32, hasState: Bool) {
        guard let state else {
            return (UInt32(OMNIWM_WORKSPACE_SESSION_VIEWPORT_NONE), 0, false)
        }

        let kind = switch state.viewOffsetPixels {
        case .static:
            UInt32(OMNIWM_WORKSPACE_SESSION_VIEWPORT_STATIC)
        case .gesture:
            UInt32(OMNIWM_WORKSPACE_SESSION_VIEWPORT_GESTURE)
        case .spring:
            UInt32(OMNIWM_WORKSPACE_SESSION_VIEWPORT_SPRING)
        }

        return (kind, Int32(clamping: state.activeColumnIndex), true)
    }

    private static func appendWindowCandidates(
        _ entries: [WindowModel.Entry],
        workspaceId: WorkspaceDescriptor.ID,
        rawMode: UInt32,
        into candidates: inout ContiguousArray<omniwm_workspace_session_window_candidate>
    ) {
        candidates.reserveCapacity(candidates.count + entries.count)
        for (index, entry) in entries.enumerated() {
            let hiddenReasonIsWorkspaceInactive: UInt8 = if case .workspaceInactive = entry.hiddenReason {
                1
            } else {
                0
            }

            candidates.append(
                omniwm_workspace_session_window_candidate(
                    workspace_id: encode(uuid: workspaceId),
                    token: encode(token: entry.token),
                    mode: rawMode,
                    order_index: UInt32(clamping: index),
                    has_hidden_proportional_position: entry.hiddenProportionalPosition == nil ? 0 : 1,
                    hidden_reason_is_workspace_inactive: hiddenReasonIsWorkspaceInactive
                )
            )
        }
    }

    private static func encode(uuid: UUID) -> omniwm_uuid {
        let tuple = uuid.uuid
        let highBytes: [UInt8] = [
            tuple.0, tuple.1, tuple.2, tuple.3,
            tuple.4, tuple.5, tuple.6, tuple.7
        ]
        let lowBytes: [UInt8] = [
            tuple.8, tuple.9, tuple.10, tuple.11,
            tuple.12, tuple.13, tuple.14, tuple.15
        ]
        return omniwm_uuid(
            high: packUUIDWord(highBytes),
            low: packUUIDWord(lowBytes)
        )
    }

    private static func decode(uuid: omniwm_uuid) -> UUID {
        let highBytes = unpackUUIDWord(uuid.high)
        let lowBytes = unpackUUIDWord(uuid.low)
        return UUID(uuid: (
            highBytes[0], highBytes[1], highBytes[2], highBytes[3],
            highBytes[4], highBytes[5], highBytes[6], highBytes[7],
            lowBytes[0], lowBytes[1], lowBytes[2], lowBytes[3],
            lowBytes[4], lowBytes[5], lowBytes[6], lowBytes[7]
        ))
    }

    private static func packUUIDWord(_ bytes: [UInt8]) -> UInt64 {
        precondition(bytes.count == 8)
        return bytes.reduce(into: UInt64.zero) { word, byte in
            word = (word << 8) | UInt64(byte)
        }
    }

    private static func unpackUUIDWord(_ word: UInt64) -> [UInt8] {
        (0 ..< 8).map { shift in
            let bitShift = UInt64((7 - shift) * 8)
            return UInt8(truncatingIfNeeded: word >> bitShift)
        }
    }

    private static func zeroUUID() -> omniwm_uuid {
        omniwm_uuid(high: 0, low: 0)
    }

    private static func encode(token: WindowToken) -> omniwm_window_token {
        omniwm_window_token(pid: token.pid, window_id: Int64(token.windowId))
    }

    private static func decode(token: omniwm_window_token) -> WindowToken {
        WindowToken(pid: token.pid, windowId: Int(token.window_id))
    }

    private static func zeroToken() -> omniwm_window_token {
        omniwm_window_token(pid: 0, window_id: 0)
    }

    private static func encode(point: CGPoint) -> omniwm_point {
        omniwm_point(x: point.x, y: point.y)
    }
}
