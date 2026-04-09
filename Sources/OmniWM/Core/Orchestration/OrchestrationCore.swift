import COmniWMKernels
import CoreGraphics
import Foundation

enum OrchestrationCore {
    static func step(
        snapshot: OrchestrationSnapshot,
        event: OrchestrationEvent
    ) -> OrchestrationResult {
        let encoder = KernelInputEncoder(snapshot: snapshot, event: event)
        var outputBuffers = KernelOutputBuffers(inputEncoder: encoder)

        return encoder.withRawInput { rawInput in
            while true {
                let (status, rawOutput) = outputBuffers.withRawOutput { rawOutput in
                    let status = withUnsafePointer(to: &rawInput) { inputPointer in
                        withUnsafeMutablePointer(to: &rawOutput) { outputPointer in
                            omniwm_orchestration_step(inputPointer, outputPointer)
                        }
                    }
                    return (status, rawOutput)
                }

                if status == OMNIWM_KERNELS_STATUS_BUFFER_TOO_SMALL {
                    outputBuffers.grow()
                    continue
                }

                precondition(
                    status == OMNIWM_KERNELS_STATUS_OK,
                    "omniwm_orchestration_step returned \(status)"
                )

                let outputView = KernelOutputView(rawOutput: rawOutput, buffers: outputBuffers)
                let decodedSnapshot = KernelDecoder.decodeSnapshot(
                    rawOutput.snapshot,
                    outputView: outputView
                )
                let decodedPlan = KernelDecoder.decodePlan(
                    decodedSnapshot: decodedSnapshot,
                    outputView: outputView
                )

                return OrchestrationResult(
                    snapshot: decodedSnapshot,
                    decision: KernelDecoder.decodeDecision(rawOutput.decision),
                    plan: decodedPlan
                )
            }
        }
    }
}

private struct KernelInputEncoder {
    var rawSnapshot: omniwm_orchestration_snapshot
    var rawEvent: omniwm_orchestration_event
    var workspaceIds = ContiguousArray<omniwm_uuid>()
    var attachmentIds = ContiguousArray<UInt64>()
    var windowRemovalPayloads = ContiguousArray<omniwm_orchestration_window_removal_payload>()
    var oldFrameRecords = ContiguousArray<omniwm_orchestration_old_frame_record>()

    init(snapshot: OrchestrationSnapshot, event: OrchestrationEvent) {
        rawSnapshot = .init()
        rawEvent = .init()
        rawSnapshot = encode(snapshot: snapshot)
        rawEvent = encode(event: event)
    }

    func withRawInput<Result>(
        _ body: (inout omniwm_orchestration_step_input) -> Result
    ) -> Result {
        workspaceIds.withUnsafeBufferPointer { workspaceBuffer in
            attachmentIds.withUnsafeBufferPointer { attachmentBuffer in
                windowRemovalPayloads.withUnsafeBufferPointer { payloadBuffer in
                    oldFrameRecords.withUnsafeBufferPointer { oldFrameBuffer in
                        var rawInput = omniwm_orchestration_step_input(
                            snapshot: rawSnapshot,
                            event: rawEvent,
                            workspace_ids: workspaceBuffer.baseAddress,
                            workspace_id_count: workspaceBuffer.count,
                            attachment_ids: attachmentBuffer.baseAddress,
                            attachment_id_count: attachmentBuffer.count,
                            window_removal_payloads: payloadBuffer.baseAddress,
                            window_removal_payload_count: payloadBuffer.count,
                            old_frame_records: oldFrameBuffer.baseAddress,
                            old_frame_record_count: oldFrameBuffer.count
                        )
                        return body(&rawInput)
                    }
                }
            }
        }
    }

    private mutating func encode(snapshot: OrchestrationSnapshot) -> omniwm_orchestration_snapshot {
        var raw = omniwm_orchestration_snapshot()
        raw.refresh = encode(refresh: snapshot.refresh)
        raw.focus = encode(focus: snapshot.focus)
        return raw
    }

    private mutating func encode(
        refresh: RefreshOrchestrationSnapshot
    ) -> omniwm_orchestration_refresh_snapshot {
        let active = encode(refresh: refresh.activeRefresh)
        let pending = encode(refresh: refresh.pendingRefresh)
        return omniwm_orchestration_refresh_snapshot(
            active_refresh: active.refresh,
            pending_refresh: pending.refresh,
            has_active_refresh: active.hasValue ? 1 : 0,
            has_pending_refresh: pending.hasValue ? 1 : 0,
            reserved0: 0,
            reserved1: 0
        )
    }

    private mutating func encode(
        focus: FocusOrchestrationSnapshot
    ) -> omniwm_orchestration_focus_snapshot {
        let activeRequest = encode(managedRequest: focus.activeManagedRequest)
        return omniwm_orchestration_focus_snapshot(
            next_managed_request_id: focus.nextManagedRequestId,
            active_managed_request: activeRequest.request,
            pending_focused_token: focus.pendingFocusedToken.map(encode(token:)) ?? zeroToken(),
            pending_focused_workspace_id: focus.pendingFocusedWorkspaceId.map(encode(uuid:)) ?? zeroUUID(),
            has_active_managed_request: activeRequest.hasValue ? 1 : 0,
            has_pending_focused_token: focus.pendingFocusedToken == nil ? 0 : 1,
            has_pending_focused_workspace_id: focus.pendingFocusedWorkspaceId == nil ? 0 : 1,
            is_non_managed_focus_active: focus.isNonManagedFocusActive ? 1 : 0,
            is_app_fullscreen_active: focus.isAppFullscreenActive ? 1 : 0,
            reserved0: 0,
            reserved1: 0,
            reserved2: 0
        )
    }

    private mutating func encode(event: OrchestrationEvent) -> omniwm_orchestration_event {
        switch event {
        case let .refreshRequested(request):
            omniwm_orchestration_event(
                kind: UInt32(OMNIWM_ORCHESTRATION_EVENT_REFRESH_REQUESTED),
                refresh_request: encode(refreshRequestEvent: request),
                refresh_completion: .init(),
                focus_request: .init(),
                activation_observation: .init()
            )
        case let .refreshCompleted(completion):
            omniwm_orchestration_event(
                kind: UInt32(OMNIWM_ORCHESTRATION_EVENT_REFRESH_COMPLETED),
                refresh_request: .init(),
                refresh_completion: encode(refreshCompletionEvent: completion),
                focus_request: .init(),
                activation_observation: .init()
            )
        case let .focusRequested(request):
            omniwm_orchestration_event(
                kind: UInt32(OMNIWM_ORCHESTRATION_EVENT_FOCUS_REQUESTED),
                refresh_request: .init(),
                refresh_completion: .init(),
                focus_request: .init(
                    token: encode(token: request.token),
                    workspace_id: encode(uuid: request.workspaceId)
                ),
                activation_observation: .init()
            )
        case let .activationObserved(observation):
            omniwm_orchestration_event(
                kind: UInt32(OMNIWM_ORCHESTRATION_EVENT_ACTIVATION_OBSERVED),
                refresh_request: .init(),
                refresh_completion: .init(),
                focus_request: .init(),
                activation_observation: encode(activationObservation: observation)
            )
        }
    }

    private mutating func encode(
        refreshRequestEvent request: RefreshRequestEvent
    ) -> omniwm_orchestration_refresh_request_event {
        let encodedRefresh = encode(refresh: request.refresh)
        return omniwm_orchestration_refresh_request_event(
            refresh: encodedRefresh.refresh,
            should_drop_while_busy: request.shouldDropWhileBusy ? 1 : 0,
            is_incremental_refresh_in_progress: request.isIncrementalRefreshInProgress ? 1 : 0,
            is_immediate_layout_in_progress: request.isImmediateLayoutInProgress ? 1 : 0,
            has_active_animation_refreshes: request.hasActiveAnimationRefreshes ? 1 : 0
        )
    }

    private mutating func encode(
        refreshCompletionEvent completion: RefreshCompletionEvent
    ) -> omniwm_orchestration_refresh_completion_event {
        let encodedRefresh = encode(refresh: completion.refresh)
        return omniwm_orchestration_refresh_completion_event(
            refresh: encodedRefresh.refresh,
            did_complete: completion.didComplete ? 1 : 0,
            did_execute_plan: completion.didExecutePlan ? 1 : 0,
            reserved0: 0,
            reserved1: 0
        )
    }

    private mutating func encode(
        activationObservation observation: ManagedActivationObservation
    ) -> omniwm_orchestration_activation_observation {
        switch observation.match {
        case let .missingFocusedWindow(pid, fallbackFullscreen):
            omniwm_orchestration_activation_observation(
                source: encode(source: observation.source),
                origin: encode(origin: observation.origin),
                match_kind: UInt32(OMNIWM_ORCHESTRATION_ACTIVATION_MATCH_MISSING_FOCUSED_WINDOW),
                pid: pid,
                token: zeroToken(),
                workspace_id: zeroUUID(),
                monitor_id: 0,
                has_token: 0,
                has_workspace_id: 0,
                has_monitor_id: 0,
                is_workspace_active: 0,
                app_fullscreen: 0,
                fallback_fullscreen: fallbackFullscreen ? 1 : 0,
                requires_native_fullscreen_restore_relayout: 0,
                reserved0: 0,
                reserved1: 0
            )

        case let .managed(
            token,
            workspaceId,
            monitorId,
            isWorkspaceActive,
            appFullscreen,
            requiresNativeFullscreenRestoreRelayout
        ):
            omniwm_orchestration_activation_observation(
                source: encode(source: observation.source),
                origin: encode(origin: observation.origin),
                match_kind: UInt32(OMNIWM_ORCHESTRATION_ACTIVATION_MATCH_MANAGED),
                pid: token.pid,
                token: encode(token: token),
                workspace_id: encode(uuid: workspaceId),
                monitor_id: monitorId.map(encode(monitorId:)) ?? 0,
                has_token: 1,
                has_workspace_id: 1,
                has_monitor_id: monitorId == nil ? 0 : 1,
                is_workspace_active: isWorkspaceActive ? 1 : 0,
                app_fullscreen: appFullscreen ? 1 : 0,
                fallback_fullscreen: 0,
                requires_native_fullscreen_restore_relayout: requiresNativeFullscreenRestoreRelayout ? 1 : 0,
                reserved0: 0,
                reserved1: 0
            )

        case let .unmanaged(pid, token, appFullscreen, fallbackFullscreen):
            omniwm_orchestration_activation_observation(
                source: encode(source: observation.source),
                origin: encode(origin: observation.origin),
                match_kind: UInt32(OMNIWM_ORCHESTRATION_ACTIVATION_MATCH_UNMANAGED),
                pid: pid,
                token: encode(token: token),
                workspace_id: zeroUUID(),
                monitor_id: 0,
                has_token: 1,
                has_workspace_id: 0,
                has_monitor_id: 0,
                is_workspace_active: 0,
                app_fullscreen: appFullscreen ? 1 : 0,
                fallback_fullscreen: fallbackFullscreen ? 1 : 0,
                requires_native_fullscreen_restore_relayout: 0,
                reserved0: 0,
                reserved1: 0
            )

        case let .ownedApplication(pid):
            omniwm_orchestration_activation_observation(
                source: encode(source: observation.source),
                origin: encode(origin: observation.origin),
                match_kind: UInt32(OMNIWM_ORCHESTRATION_ACTIVATION_MATCH_OWNED_APPLICATION),
                pid: pid,
                token: zeroToken(),
                workspace_id: zeroUUID(),
                monitor_id: 0,
                has_token: 0,
                has_workspace_id: 0,
                has_monitor_id: 0,
                is_workspace_active: 0,
                app_fullscreen: 0,
                fallback_fullscreen: 0,
                requires_native_fullscreen_restore_relayout: 0,
                reserved0: 0,
                reserved1: 0
            )
        }
    }

    private mutating func encode(
        refresh: ScheduledRefresh?
    ) -> (refresh: omniwm_orchestration_refresh, hasValue: Bool) {
        guard let refresh else {
            return (.init(), false)
        }

        let affectedWorkspaceIds = appendWorkspaceIds(refresh.affectedWorkspaceIds)
        let attachmentIds = appendAttachmentIds(refresh.postLayoutAttachmentIds)
        let payloads = appendWindowRemovalPayloads(refresh.windowRemovalPayloads)
        let followUp = encode(followUpRefresh: refresh.followUpRefresh)

        return (
            omniwm_orchestration_refresh(
                cycle_id: refresh.cycleId,
                kind: encode(refreshKind: refresh.kind),
                reason: encode(refreshReason: refresh.reason),
                affected_workspace_offset: affectedWorkspaceIds.offset,
                affected_workspace_count: affectedWorkspaceIds.count,
                post_layout_attachment_offset: attachmentIds.offset,
                post_layout_attachment_count: attachmentIds.count,
                window_removal_payload_offset: payloads.offset,
                window_removal_payload_count: payloads.count,
                follow_up_refresh: followUp.followUp,
                visibility_reason: refresh.visibilityReason.map(encode(refreshReason:)) ?? 0,
                has_follow_up_refresh: followUp.hasValue ? 1 : 0,
                needs_visibility_reconciliation: refresh.needsVisibilityReconciliation ? 1 : 0,
                has_visibility_reason: refresh.visibilityReason == nil ? 0 : 1,
                reserved0: 0
            ),
            true
        )
    }

    private mutating func encode(
        followUpRefresh: FollowUpRefresh?
    ) -> (followUp: omniwm_orchestration_follow_up_refresh, hasValue: Bool) {
        guard let followUpRefresh else {
            return (.init(), false)
        }

        let workspaceIds = appendWorkspaceIds(followUpRefresh.affectedWorkspaceIds)
        return (
            omniwm_orchestration_follow_up_refresh(
                kind: encode(refreshKind: followUpRefresh.kind),
                reason: encode(refreshReason: followUpRefresh.reason),
                affected_workspace_offset: workspaceIds.offset,
                affected_workspace_count: workspaceIds.count
            ),
            true
        )
    }

    private mutating func encode(
        managedRequest: ManagedFocusRequest?
    ) -> (request: omniwm_orchestration_managed_request, hasValue: Bool) {
        guard let managedRequest else {
            return (.init(), false)
        }

        return (
            omniwm_orchestration_managed_request(
                request_id: managedRequest.requestId,
                token: encode(token: managedRequest.token),
                workspace_id: encode(uuid: managedRequest.workspaceId),
                retry_count: UInt32(managedRequest.retryCount),
                last_activation_source: managedRequest.lastActivationSource.map(encode(source:)) ?? 0,
                has_last_activation_source: managedRequest.lastActivationSource == nil ? 0 : 1,
                reserved0: 0,
                reserved1: 0,
                reserved2: 0
            ),
            true
        )
    }

    private mutating func appendWorkspaceIds(
        _ workspaceIds: Set<WorkspaceDescriptor.ID>
    ) -> (offset: Int, count: Int) {
        let ordered = workspaceIds.sorted { $0.uuidString < $1.uuidString }
        return appendWorkspaceIds(ordered)
    }

    private mutating func appendWorkspaceIds(
        _ workspaceIds: [WorkspaceDescriptor.ID]
    ) -> (offset: Int, count: Int) {
        let offset = self.workspaceIds.count
        self.workspaceIds.append(contentsOf: workspaceIds.map(encode(uuid:)))
        return (offset, workspaceIds.count)
    }

    private mutating func appendAttachmentIds(
        _ attachmentIds: [RefreshAttachmentId]
    ) -> (offset: Int, count: Int) {
        let offset = self.attachmentIds.count
        self.attachmentIds.append(contentsOf: attachmentIds)
        return (offset, attachmentIds.count)
    }

    private mutating func appendWindowRemovalPayloads(
        _ payloads: [WindowRemovalPayload]
    ) -> (offset: Int, count: Int) {
        let offset = windowRemovalPayloads.count

        for payload in payloads {
            let oldFrames = payload.niriOldFrames.sorted { lhs, rhs in
                if lhs.key.pid != rhs.key.pid {
                    lhs.key.pid < rhs.key.pid
                } else {
                    lhs.key.windowId < rhs.key.windowId
                }
            }
            let oldFrameOffset = oldFrameRecords.count
            oldFrameRecords.append(
                contentsOf: oldFrames.map { token, frame in
                    omniwm_orchestration_old_frame_record(
                        token: encode(token: token),
                        frame: encode(rect: frame)
                    )
                }
            )

            windowRemovalPayloads.append(
                omniwm_orchestration_window_removal_payload(
                    workspace_id: encode(uuid: payload.workspaceId),
                    removed_node_id: payload.removedNodeId.map { encode(uuid: $0.uuid) } ?? zeroUUID(),
                    layout_kind: encode(layoutType: payload.layoutType),
                    has_removed_node_id: payload.removedNodeId == nil ? 0 : 1,
                    should_recover_focus: payload.shouldRecoverFocus ? 1 : 0,
                    reserved0: 0,
                    reserved1: 0,
                    old_frame_offset: oldFrameOffset,
                    old_frame_count: oldFrames.count
                )
            )
        }

        return (offset, payloads.count)
    }

    private func encode(token: WindowToken) -> omniwm_window_token {
        omniwm_window_token(pid: token.pid, window_id: Int64(token.windowId))
    }

    private func encode(uuid: UUID) -> omniwm_uuid {
        let bytes = Array(withUnsafeBytes(of: uuid.uuid) { $0 })
        let high = bytes[0 ..< 8].reduce(UInt64.zero) { ($0 << 8) | UInt64($1) }
        let low = bytes[8 ..< 16].reduce(UInt64.zero) { ($0 << 8) | UInt64($1) }
        return omniwm_uuid(high: high, low: low)
    }

    private func encode(rect: CGRect) -> omniwm_rect {
        omniwm_rect(
            x: rect.origin.x,
            y: rect.origin.y,
            width: rect.size.width,
            height: rect.size.height
        )
    }

    private func encode(refreshKind: ScheduledRefreshKind) -> UInt32 {
        switch refreshKind {
        case .relayout:
            UInt32(OMNIWM_ORCHESTRATION_REFRESH_KIND_RELAYOUT)
        case .immediateRelayout:
            UInt32(OMNIWM_ORCHESTRATION_REFRESH_KIND_IMMEDIATE_RELAYOUT)
        case .visibilityRefresh:
            UInt32(OMNIWM_ORCHESTRATION_REFRESH_KIND_VISIBILITY_REFRESH)
        case .windowRemoval:
            UInt32(OMNIWM_ORCHESTRATION_REFRESH_KIND_WINDOW_REMOVAL)
        case .fullRescan:
            UInt32(OMNIWM_ORCHESTRATION_REFRESH_KIND_FULL_RESCAN)
        }
    }

    private func encode(refreshReason: RefreshReason) -> UInt32 {
        switch refreshReason {
        case .startup:
            UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_STARTUP)
        case .appLaunched:
            UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_APP_LAUNCHED)
        case .unlock:
            UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_UNLOCK)
        case .activeSpaceChanged:
            UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_ACTIVE_SPACE_CHANGED)
        case .monitorConfigurationChanged:
            UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_MONITOR_CONFIGURATION_CHANGED)
        case .appRulesChanged:
            UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_APP_RULES_CHANGED)
        case .workspaceConfigChanged:
            UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_WORKSPACE_CONFIG_CHANGED)
        case .layoutConfigChanged:
            UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_LAYOUT_CONFIG_CHANGED)
        case .monitorSettingsChanged:
            UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_MONITOR_SETTINGS_CHANGED)
        case .gapsChanged:
            UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_GAPS_CHANGED)
        case .workspaceTransition:
            UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_WORKSPACE_TRANSITION)
        case .appActivationTransition:
            UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_APP_ACTIVATION_TRANSITION)
        case .workspaceLayoutToggled:
            UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_WORKSPACE_LAYOUT_TOGGLED)
        case .appTerminated:
            UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_APP_TERMINATED)
        case .windowRuleReevaluation:
            UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_WINDOW_RULE_REEVALUATION)
        case .layoutCommand:
            UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_LAYOUT_COMMAND)
        case .interactiveGesture:
            UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_INTERACTIVE_GESTURE)
        case .axWindowCreated:
            UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_AX_WINDOW_CREATED)
        case .axWindowChanged:
            UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_AX_WINDOW_CHANGED)
        case .windowDestroyed:
            UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_WINDOW_DESTROYED)
        case .appHidden:
            UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_APP_HIDDEN)
        case .appUnhidden:
            UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_APP_UNHIDDEN)
        case .overviewMutation:
            UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_OVERVIEW_MUTATION)
        }
    }

    private func encode(layoutType: LayoutType) -> UInt32 {
        switch layoutType {
        case .defaultLayout:
            UInt32(OMNIWM_ORCHESTRATION_LAYOUT_KIND_DEFAULT)
        case .niri:
            UInt32(OMNIWM_ORCHESTRATION_LAYOUT_KIND_NIRI)
        case .dwindle:
            UInt32(OMNIWM_ORCHESTRATION_LAYOUT_KIND_DWINDLE)
        }
    }

    private func encode(source: ActivationEventSource) -> UInt32 {
        switch source {
        case .focusedWindowChanged:
            UInt32(OMNIWM_ORCHESTRATION_ACTIVATION_SOURCE_FOCUSED_WINDOW_CHANGED)
        case .workspaceDidActivateApplication:
            UInt32(OMNIWM_ORCHESTRATION_ACTIVATION_SOURCE_WORKSPACE_DID_ACTIVATE_APPLICATION)
        case .cgsFrontAppChanged:
            UInt32(OMNIWM_ORCHESTRATION_ACTIVATION_SOURCE_CGS_FRONT_APP_CHANGED)
        }
    }

    private func encode(origin: ActivationCallOrigin) -> UInt32 {
        switch origin {
        case .external:
            UInt32(OMNIWM_ORCHESTRATION_ACTIVATION_ORIGIN_EXTERNAL)
        case .probe:
            UInt32(OMNIWM_ORCHESTRATION_ACTIVATION_ORIGIN_PROBE)
        case .retry:
            UInt32(OMNIWM_ORCHESTRATION_ACTIVATION_ORIGIN_RETRY)
        }
    }

    private func encode(monitorId: Monitor.ID) -> UInt32 {
        monitorId.displayId
    }

    private func zeroUUID() -> omniwm_uuid {
        omniwm_uuid(high: 0, low: 0)
    }

    private func zeroToken() -> omniwm_window_token {
        omniwm_window_token(pid: 0, window_id: 0)
    }
}

private struct KernelOutputBuffers {
    private static let maximumCapacity = 1 << 20

    var actions: ContiguousArray<omniwm_orchestration_action>
    var snapshotWorkspaceIds: ContiguousArray<omniwm_uuid>
    var snapshotAttachmentIds: ContiguousArray<UInt64>
    var snapshotWindowRemovalPayloads: ContiguousArray<omniwm_orchestration_window_removal_payload>
    var snapshotOldFrameRecords: ContiguousArray<omniwm_orchestration_old_frame_record>
    var actionAttachmentIds: ContiguousArray<UInt64>

    init(inputEncoder: KernelInputEncoder) {
        actions = ContiguousArray(
            repeating: omniwm_orchestration_action(),
            count: 16
        )
        snapshotWorkspaceIds = ContiguousArray(
            repeating: omniwm_uuid(),
            count: inputEncoder.workspaceIds.count
        )
        snapshotAttachmentIds = ContiguousArray(
            repeating: 0,
            count: inputEncoder.attachmentIds.count
        )
        snapshotWindowRemovalPayloads = ContiguousArray(
            repeating: omniwm_orchestration_window_removal_payload(),
            count: inputEncoder.windowRemovalPayloads.count
        )
        snapshotOldFrameRecords = ContiguousArray(
            repeating: omniwm_orchestration_old_frame_record(),
            count: inputEncoder.oldFrameRecords.count
        )
        actionAttachmentIds = ContiguousArray(
            repeating: 0,
            count: inputEncoder.attachmentIds.count
        )
    }

    mutating func grow() {
        actions = grownArray(actions, filler: omniwm_orchestration_action())
        snapshotWorkspaceIds = grownArray(snapshotWorkspaceIds, filler: omniwm_uuid())
        snapshotAttachmentIds = grownArray(snapshotAttachmentIds, filler: 0)
        snapshotWindowRemovalPayloads = grownArray(
            snapshotWindowRemovalPayloads,
            filler: omniwm_orchestration_window_removal_payload()
        )
        snapshotOldFrameRecords = grownArray(
            snapshotOldFrameRecords,
            filler: omniwm_orchestration_old_frame_record()
        )
        actionAttachmentIds = grownArray(actionAttachmentIds, filler: 0)
    }

    private func grownArray<Element>(
        _ values: ContiguousArray<Element>,
        filler: Element
    ) -> ContiguousArray<Element> {
        let nextCount = Self.grownCapacity(values.count)
        var grown = values
        grown.append(
            contentsOf: repeatElement(
                filler,
                count: nextCount - values.count
            )
        )
        return grown
    }

    private static func grownCapacity(_ count: Int) -> Int {
        precondition(
            count < maximumCapacity,
            "omniwm_orchestration_step output exceeded \(maximumCapacity) records"
        )
        return min(max(count * 2, 1), maximumCapacity)
    }

    mutating func withRawOutput<Result>(
        _ body: (inout omniwm_orchestration_step_output) -> Result
    ) -> Result {
        actions.withUnsafeMutableBufferPointer { actionBuffer in
            snapshotWorkspaceIds.withUnsafeMutableBufferPointer { workspaceBuffer in
                snapshotAttachmentIds.withUnsafeMutableBufferPointer { snapshotAttachmentBuffer in
                    snapshotWindowRemovalPayloads.withUnsafeMutableBufferPointer { payloadBuffer in
                        snapshotOldFrameRecords.withUnsafeMutableBufferPointer { oldFrameBuffer in
                            actionAttachmentIds.withUnsafeMutableBufferPointer { actionAttachmentBuffer in
                                var rawOutput = omniwm_orchestration_step_output(
                                    snapshot: .init(),
                                    decision: .init(),
                                    actions: actionBuffer.baseAddress,
                                    action_capacity: actionBuffer.count,
                                    action_count: 0,
                                    snapshot_workspace_ids: workspaceBuffer.baseAddress,
                                    snapshot_workspace_id_capacity: workspaceBuffer.count,
                                    snapshot_workspace_id_count: 0,
                                    snapshot_attachment_ids: snapshotAttachmentBuffer.baseAddress,
                                    snapshot_attachment_id_capacity: snapshotAttachmentBuffer.count,
                                    snapshot_attachment_id_count: 0,
                                    snapshot_window_removal_payloads: payloadBuffer.baseAddress,
                                    snapshot_window_removal_payload_capacity: payloadBuffer.count,
                                    snapshot_window_removal_payload_count: 0,
                                    snapshot_old_frame_records: oldFrameBuffer.baseAddress,
                                    snapshot_old_frame_record_capacity: oldFrameBuffer.count,
                                    snapshot_old_frame_record_count: 0,
                                    action_attachment_ids: actionAttachmentBuffer.baseAddress,
                                    action_attachment_id_capacity: actionAttachmentBuffer.count,
                                    action_attachment_id_count: 0
                                )
                                return body(&rawOutput)
                            }
                        }
                    }
                }
            }
        }
    }
}

private extension NodeId {
    init(uuid: UUID) {
        self.uuid = uuid
    }
}

private struct KernelOutputView {
    let snapshotWorkspaceIds: [omniwm_uuid]
    let snapshotAttachmentIds: [UInt64]
    let snapshotWindowRemovalPayloads: [omniwm_orchestration_window_removal_payload]
    let snapshotOldFrameRecords: [omniwm_orchestration_old_frame_record]
    let actions: [omniwm_orchestration_action]
    let actionAttachmentIds: [UInt64]

    init(rawOutput: omniwm_orchestration_step_output, buffers: KernelOutputBuffers) {
        snapshotWorkspaceIds = Array(buffers.snapshotWorkspaceIds.prefix(rawOutput.snapshot_workspace_id_count))
        snapshotAttachmentIds = Array(buffers.snapshotAttachmentIds.prefix(rawOutput.snapshot_attachment_id_count))
        snapshotWindowRemovalPayloads = Array(
            buffers.snapshotWindowRemovalPayloads.prefix(rawOutput.snapshot_window_removal_payload_count)
        )
        snapshotOldFrameRecords = Array(
            buffers.snapshotOldFrameRecords.prefix(rawOutput.snapshot_old_frame_record_count)
        )
        actions = Array(buffers.actions.prefix(rawOutput.action_count))
        actionAttachmentIds = Array(buffers.actionAttachmentIds.prefix(rawOutput.action_attachment_id_count))
    }
}

private enum KernelDecoder {
    static func decodeSnapshot(
        _ raw: omniwm_orchestration_snapshot,
        outputView: KernelOutputView
    ) -> OrchestrationSnapshot {
        OrchestrationSnapshot(
            refresh: .init(
                activeRefresh: decode(
                    refresh: raw.refresh.active_refresh,
                    hasValue: raw.refresh.has_active_refresh != 0,
                    buffers: outputView
                ),
                pendingRefresh: decode(
                    refresh: raw.refresh.pending_refresh,
                    hasValue: raw.refresh.has_pending_refresh != 0,
                    buffers: outputView
                )
            ),
            focus: .init(
                nextManagedRequestId: raw.focus.next_managed_request_id,
                activeManagedRequest: raw.focus.has_active_managed_request != 0
                    ? decode(managedRequest: raw.focus.active_managed_request)
                    : nil,
                pendingFocusedToken: raw.focus.has_pending_focused_token != 0
                    ? decode(token: raw.focus.pending_focused_token)
                    : nil,
                pendingFocusedWorkspaceId: raw.focus.has_pending_focused_workspace_id != 0
                    ? decode(uuid: raw.focus.pending_focused_workspace_id)
                    : nil,
                isNonManagedFocusActive: raw.focus.is_non_managed_focus_active != 0,
                isAppFullscreenActive: raw.focus.is_app_fullscreen_active != 0
            )
        )
    }

    static func decodePlan(
        decodedSnapshot: OrchestrationSnapshot,
        outputView: KernelOutputView
    ) -> OrchestrationPlan {
        var decodedActions: [OrchestrationPlan.Action] = []
        decodedActions.reserveCapacity(outputView.actions.count)

        for rawAction in outputView.actions {
            switch rawAction.kind {
            case UInt32(OMNIWM_ORCHESTRATION_ACTION_CANCEL_ACTIVE_REFRESH):
                decodedActions.append(.cancelActiveRefresh(cycleId: rawAction.cycle_id))

            case UInt32(OMNIWM_ORCHESTRATION_ACTION_START_REFRESH):
                guard let activeRefresh = decodedSnapshot.refresh.activeRefresh else {
                    preconditionFailure("startRefresh action missing active refresh")
                }
                precondition(
                    activeRefresh.cycleId == rawAction.cycle_id,
                    "startRefresh action cycle \(rawAction.cycle_id) did not match active refresh \(activeRefresh.cycleId)"
                )
                decodedActions.append(.startRefresh(activeRefresh))

            case UInt32(OMNIWM_ORCHESTRATION_ACTION_RUN_POST_LAYOUT_ATTACHMENTS):
                decodedActions.append(
                    .runPostLayoutAttachments(
                        decodeAttachmentIds(
                            offset: rawAction.attachment_offset,
                            count: rawAction.attachment_count,
                            buffer: outputView.actionAttachmentIds
                        )
                    )
                )

            case UInt32(OMNIWM_ORCHESTRATION_ACTION_DISCARD_POST_LAYOUT_ATTACHMENTS):
                decodedActions.append(
                    .discardPostLayoutAttachments(
                        decodeAttachmentIds(
                            offset: rawAction.attachment_offset,
                            count: rawAction.attachment_count,
                            buffer: outputView.actionAttachmentIds
                        )
                    )
                )

            case UInt32(OMNIWM_ORCHESTRATION_ACTION_PERFORM_VISIBILITY_SIDE_EFFECTS):
                decodedActions.append(.performVisibilitySideEffects)

            case UInt32(OMNIWM_ORCHESTRATION_ACTION_REQUEST_WORKSPACE_BAR_REFRESH):
                decodedActions.append(.requestWorkspaceBarRefresh)

            case UInt32(OMNIWM_ORCHESTRATION_ACTION_BEGIN_MANAGED_FOCUS_REQUEST):
                decodedActions.append(
                    .beginManagedFocusRequest(
                        requestId: rawAction.request_id,
                        token: decode(token: rawAction.token),
                        workspaceId: decode(uuid: rawAction.workspace_id)
                    )
                )

            case UInt32(OMNIWM_ORCHESTRATION_ACTION_FRONT_MANAGED_WINDOW):
                decodedActions.append(
                    .frontManagedWindow(
                        token: decode(token: rawAction.token),
                        workspaceId: decode(uuid: rawAction.workspace_id)
                    )
                )

            case UInt32(OMNIWM_ORCHESTRATION_ACTION_CLEAR_MANAGED_FOCUS_STATE):
                decodedActions.append(
                    .clearManagedFocusState(
                        requestId: rawAction.request_id,
                        token: decode(token: rawAction.token),
                        workspaceId: rawAction.has_workspace_id != 0
                            ? decode(uuid: rawAction.workspace_id)
                            : nil
                    )
                )

            case UInt32(OMNIWM_ORCHESTRATION_ACTION_CONTINUE_MANAGED_FOCUS_REQUEST):
                decodedActions.append(
                    .continueManagedFocusRequest(
                        requestId: rawAction.request_id,
                        reason: decode(retryReason: rawAction.retry_reason),
                        source: decode(source: rawAction.activation_source),
                        origin: decode(origin: rawAction.activation_origin)
                    )
                )

            case UInt32(OMNIWM_ORCHESTRATION_ACTION_CONFIRM_MANAGED_ACTIVATION):
                decodedActions.append(
                    .confirmManagedActivation(
                        token: decode(token: rawAction.token),
                        workspaceId: decode(uuid: rawAction.workspace_id),
                        monitorId: rawAction.has_monitor_id != 0
                            ? decode(monitorId: rawAction.monitor_id)
                            : nil,
                        isWorkspaceActive: rawAction.is_workspace_active != 0,
                        appFullscreen: rawAction.app_fullscreen != 0,
                        source: decode(source: rawAction.activation_source)
                    )
                )

            case UInt32(OMNIWM_ORCHESTRATION_ACTION_BEGIN_NATIVE_FULLSCREEN_RESTORE_ACTIVATION):
                decodedActions.append(
                    .beginNativeFullscreenRestoreActivation(
                        token: decode(token: rawAction.token),
                        workspaceId: decode(uuid: rawAction.workspace_id),
                        monitorId: rawAction.has_monitor_id != 0
                            ? decode(monitorId: rawAction.monitor_id)
                            : nil,
                        isWorkspaceActive: rawAction.is_workspace_active != 0,
                        source: decode(source: rawAction.activation_source)
                    )
                )

            case UInt32(OMNIWM_ORCHESTRATION_ACTION_ENTER_NON_MANAGED_FALLBACK):
                decodedActions.append(
                    .enterNonManagedFallback(
                        pid: rawAction.pid,
                        token: rawAction.has_token != 0 ? decode(token: rawAction.token) : nil,
                        appFullscreen: rawAction.app_fullscreen != 0,
                        source: decode(source: rawAction.activation_source)
                    )
                )

            case UInt32(OMNIWM_ORCHESTRATION_ACTION_CANCEL_ACTIVATION_RETRY):
                decodedActions.append(
                    .cancelActivationRetry(
                        requestId: rawAction.request_id == 0 ? nil : rawAction.request_id
                    )
                )

            case UInt32(OMNIWM_ORCHESTRATION_ACTION_ENTER_OWNED_APPLICATION_FALLBACK):
                decodedActions.append(
                    .enterOwnedApplicationFallback(
                        pid: rawAction.pid,
                        source: decode(source: rawAction.activation_source)
                    )
                )

            default:
                preconditionFailure("Unknown orchestration action \(rawAction.kind)")
            }
        }

        return OrchestrationPlan(actions: decodedActions)
    }

    static func decodeDecision(
        _ raw: omniwm_orchestration_decision
    ) -> OrchestrationDecision {
        switch raw.kind {
        case UInt32(OMNIWM_ORCHESTRATION_DECISION_REFRESH_DROPPED):
            .refreshDropped(reason: decode(refreshReason: raw.refresh_reason))

        case UInt32(OMNIWM_ORCHESTRATION_DECISION_REFRESH_QUEUED):
            .refreshQueued(
                cycleId: raw.cycle_id,
                kind: decode(refreshKind: raw.refresh_kind)
            )

        case UInt32(OMNIWM_ORCHESTRATION_DECISION_REFRESH_MERGED):
            .refreshMerged(
                cycleId: raw.cycle_id,
                kind: decode(refreshKind: raw.refresh_kind)
            )

        case UInt32(OMNIWM_ORCHESTRATION_DECISION_REFRESH_SUPERSEDED):
            .refreshSuperseded(
                activeCycleId: raw.cycle_id,
                pendingCycleId: raw.secondary_cycle_id
            )

        case UInt32(OMNIWM_ORCHESTRATION_DECISION_REFRESH_COMPLETED):
            .refreshCompleted(
                cycleId: raw.cycle_id,
                didComplete: raw.did_complete != 0
            )

        case UInt32(OMNIWM_ORCHESTRATION_DECISION_FOCUS_REQUEST_ACCEPTED):
            .focusRequestAccepted(
                requestId: raw.request_id,
                token: decode(token: raw.token)
            )

        case UInt32(OMNIWM_ORCHESTRATION_DECISION_FOCUS_REQUEST_SUPERSEDED):
            .focusRequestSuperseded(
                replacedRequestId: raw.secondary_request_id,
                requestId: raw.request_id,
                token: decode(token: raw.token)
            )

        case UInt32(OMNIWM_ORCHESTRATION_DECISION_FOCUS_REQUEST_CONTINUED):
            .focusRequestContinued(
                requestId: raw.request_id,
                reason: decode(retryReason: raw.retry_reason)
            )

        case UInt32(OMNIWM_ORCHESTRATION_DECISION_FOCUS_REQUEST_CANCELLED):
            .focusRequestCancelled(
                requestId: raw.request_id,
                token: raw.has_token != 0 ? decode(token: raw.token) : nil
            )

        case UInt32(OMNIWM_ORCHESTRATION_DECISION_FOCUS_REQUEST_IGNORED):
            .focusRequestIgnored(token: decode(token: raw.token))

        case UInt32(OMNIWM_ORCHESTRATION_DECISION_MANAGED_ACTIVATION_CONFIRMED):
            .managedActivationConfirmed(token: decode(token: raw.token))

        case UInt32(OMNIWM_ORCHESTRATION_DECISION_MANAGED_ACTIVATION_DEFERRED):
            .managedActivationDeferred(
                requestId: raw.request_id,
                reason: decode(retryReason: raw.retry_reason)
            )

        case UInt32(OMNIWM_ORCHESTRATION_DECISION_MANAGED_ACTIVATION_FALLBACK):
            .managedActivationFallback(pid: raw.pid)

        default:
            preconditionFailure("Unknown orchestration decision \(raw.kind)")
        }
    }

    private static func decode(
        refresh raw: omniwm_orchestration_refresh,
        hasValue: Bool,
        buffers: KernelOutputView
    ) -> ScheduledRefresh? {
        guard hasValue else { return nil }

        var refresh = ScheduledRefresh(
            cycleId: raw.cycle_id,
            kind: decode(refreshKind: raw.kind),
            reason: decode(refreshReason: raw.reason),
            affectedWorkspaceIds: Set(
                decodeWorkspaceIds(
                    offset: raw.affected_workspace_offset,
                    count: raw.affected_workspace_count,
                    buffer: buffers.snapshotWorkspaceIds
                )
            ),
            postLayoutAttachmentIds: decodeAttachmentIds(
                offset: raw.post_layout_attachment_offset,
                count: raw.post_layout_attachment_count,
                buffer: buffers.snapshotAttachmentIds
            ),
            windowRemovalPayload: nil
        )
        refresh.windowRemovalPayloads = decodeWindowRemovalPayloads(
            offset: raw.window_removal_payload_offset,
            count: raw.window_removal_payload_count,
            payloadBuffer: buffers.snapshotWindowRemovalPayloads,
            oldFrameBuffer: buffers.snapshotOldFrameRecords
        )
        refresh.followUpRefresh = raw.has_follow_up_refresh != 0
            ? FollowUpRefresh(
                kind: decode(refreshKind: raw.follow_up_refresh.kind),
                reason: decode(refreshReason: raw.follow_up_refresh.reason),
                affectedWorkspaceIds: Set(
                    decodeWorkspaceIds(
                        offset: raw.follow_up_refresh.affected_workspace_offset,
                        count: raw.follow_up_refresh.affected_workspace_count,
                        buffer: buffers.snapshotWorkspaceIds
                    )
                )
            )
            : nil
        refresh.needsVisibilityReconciliation = raw.needs_visibility_reconciliation != 0
        refresh.visibilityReason = raw.has_visibility_reason != 0
            ? decode(refreshReason: raw.visibility_reason)
            : nil
        return refresh
    }

    private static func decode(
        managedRequest raw: omniwm_orchestration_managed_request
    ) -> ManagedFocusRequest {
        ManagedFocusRequest(
            requestId: raw.request_id,
            token: decode(token: raw.token),
            workspaceId: decode(uuid: raw.workspace_id),
            retryCount: Int(raw.retry_count),
            lastActivationSource: raw.has_last_activation_source != 0
                ? decode(source: raw.last_activation_source)
                : nil
        )
    }

    private static func decodeWorkspaceIds(
        offset: Int,
        count: Int,
        buffer: [omniwm_uuid]
    ) -> [WorkspaceDescriptor.ID] {
        guard count > 0 else { return [] }
        precondition(offset >= 0 && count >= 0 && offset + count <= buffer.count)
        return buffer[offset ..< (offset + count)].map(decode(uuid:))
    }

    private static func decodeAttachmentIds(
        offset: Int,
        count: Int,
        buffer: [UInt64]
    ) -> [RefreshAttachmentId] {
        guard count > 0 else { return [] }
        precondition(offset >= 0 && count >= 0 && offset + count <= buffer.count)
        return Array(buffer[offset ..< (offset + count)])
    }

    private static func decodeWindowRemovalPayloads(
        offset: Int,
        count: Int,
        payloadBuffer: [omniwm_orchestration_window_removal_payload],
        oldFrameBuffer: [omniwm_orchestration_old_frame_record]
    ) -> [WindowRemovalPayload] {
        guard count > 0 else { return [] }
        precondition(offset >= 0 && count >= 0 && offset + count <= payloadBuffer.count)
        return payloadBuffer[offset ..< (offset + count)].map { rawPayload in
            let oldFrameOffset = Int(rawPayload.old_frame_offset)
            let oldFrameCount = Int(rawPayload.old_frame_count)
            precondition(
                oldFrameOffset >= 0 && oldFrameCount >= 0
                    && oldFrameOffset + oldFrameCount <= oldFrameBuffer.count
            )

            let oldFrames = oldFrameBuffer[oldFrameOffset ..< (oldFrameOffset + oldFrameCount)]
            var niriOldFrames: [WindowToken: CGRect] = [:]
            niriOldFrames.reserveCapacity(oldFrames.count)
            for record in oldFrames {
                let token = decode(token: record.token)
                precondition(
                    niriOldFrames[token] == nil,
                    "Duplicate orchestration old-frame record for \(token)"
                )
                niriOldFrames[token] = decode(rect: record.frame)
            }

            return WindowRemovalPayload(
                workspaceId: decode(uuid: rawPayload.workspace_id),
                layoutType: decode(layoutType: rawPayload.layout_kind),
                removedNodeId: rawPayload.has_removed_node_id != 0
                    ? NodeId(uuid: decode(uuid: rawPayload.removed_node_id))
                    : nil,
                niriOldFrames: niriOldFrames,
                shouldRecoverFocus: rawPayload.should_recover_focus != 0
            )
        }
    }

    private static func decode(token: omniwm_window_token) -> WindowToken {
        WindowToken(pid: token.pid, windowId: Int(token.window_id))
    }

    private static func decode(uuid: omniwm_uuid) -> UUID {
        let b0 = UInt8((uuid.high >> 56) & 0xFF)
        let b1 = UInt8((uuid.high >> 48) & 0xFF)
        let b2 = UInt8((uuid.high >> 40) & 0xFF)
        let b3 = UInt8((uuid.high >> 32) & 0xFF)
        let b4 = UInt8((uuid.high >> 24) & 0xFF)
        let b5 = UInt8((uuid.high >> 16) & 0xFF)
        let b6 = UInt8((uuid.high >> 8) & 0xFF)
        let b7 = UInt8(uuid.high & 0xFF)
        let b8 = UInt8((uuid.low >> 56) & 0xFF)
        let b9 = UInt8((uuid.low >> 48) & 0xFF)
        let b10 = UInt8((uuid.low >> 40) & 0xFF)
        let b11 = UInt8((uuid.low >> 32) & 0xFF)
        let b12 = UInt8((uuid.low >> 24) & 0xFF)
        let b13 = UInt8((uuid.low >> 16) & 0xFF)
        let b14 = UInt8((uuid.low >> 8) & 0xFF)
        let b15 = UInt8(uuid.low & 0xFF)
        return UUID(uuid: (b0, b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12, b13, b14, b15))
    }

    private static func decode(rect: omniwm_rect) -> CGRect {
        CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }

    private static func decode(refreshKind: UInt32) -> ScheduledRefreshKind {
        switch refreshKind {
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_KIND_RELAYOUT):
            .relayout
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_KIND_IMMEDIATE_RELAYOUT):
            .immediateRelayout
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_KIND_VISIBILITY_REFRESH):
            .visibilityRefresh
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_KIND_WINDOW_REMOVAL):
            .windowRemoval
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_KIND_FULL_RESCAN):
            .fullRescan
        default:
            preconditionFailure("Unknown orchestration refresh kind \(refreshKind)")
        }
    }

    private static func decode(refreshReason: UInt32) -> RefreshReason {
        switch refreshReason {
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_STARTUP):
            .startup
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_APP_LAUNCHED):
            .appLaunched
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_UNLOCK):
            .unlock
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_ACTIVE_SPACE_CHANGED):
            .activeSpaceChanged
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_MONITOR_CONFIGURATION_CHANGED):
            .monitorConfigurationChanged
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_APP_RULES_CHANGED):
            .appRulesChanged
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_WORKSPACE_CONFIG_CHANGED):
            .workspaceConfigChanged
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_LAYOUT_CONFIG_CHANGED):
            .layoutConfigChanged
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_MONITOR_SETTINGS_CHANGED):
            .monitorSettingsChanged
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_GAPS_CHANGED):
            .gapsChanged
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_WORKSPACE_TRANSITION):
            .workspaceTransition
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_APP_ACTIVATION_TRANSITION):
            .appActivationTransition
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_WORKSPACE_LAYOUT_TOGGLED):
            .workspaceLayoutToggled
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_APP_TERMINATED):
            .appTerminated
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_WINDOW_RULE_REEVALUATION):
            .windowRuleReevaluation
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_LAYOUT_COMMAND):
            .layoutCommand
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_INTERACTIVE_GESTURE):
            .interactiveGesture
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_AX_WINDOW_CREATED):
            .axWindowCreated
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_AX_WINDOW_CHANGED):
            .axWindowChanged
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_WINDOW_DESTROYED):
            .windowDestroyed
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_APP_HIDDEN):
            .appHidden
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_APP_UNHIDDEN):
            .appUnhidden
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_OVERVIEW_MUTATION):
            .overviewMutation
        default:
            preconditionFailure("Unknown orchestration refresh reason \(refreshReason)")
        }
    }

    private static func decode(layoutType: UInt32) -> LayoutType {
        switch layoutType {
        case UInt32(OMNIWM_ORCHESTRATION_LAYOUT_KIND_DEFAULT):
            .defaultLayout
        case UInt32(OMNIWM_ORCHESTRATION_LAYOUT_KIND_NIRI):
            .niri
        case UInt32(OMNIWM_ORCHESTRATION_LAYOUT_KIND_DWINDLE):
            .dwindle
        default:
            preconditionFailure("Unknown orchestration layout kind \(layoutType)")
        }
    }

    private static func decode(source: UInt32) -> ActivationEventSource {
        switch source {
        case UInt32(OMNIWM_ORCHESTRATION_ACTIVATION_SOURCE_FOCUSED_WINDOW_CHANGED):
            .focusedWindowChanged
        case UInt32(OMNIWM_ORCHESTRATION_ACTIVATION_SOURCE_WORKSPACE_DID_ACTIVATE_APPLICATION):
            .workspaceDidActivateApplication
        case UInt32(OMNIWM_ORCHESTRATION_ACTIVATION_SOURCE_CGS_FRONT_APP_CHANGED):
            .cgsFrontAppChanged
        default:
            preconditionFailure("Unknown orchestration activation source \(source)")
        }
    }

    private static func decode(origin: UInt32) -> ActivationCallOrigin {
        switch origin {
        case UInt32(OMNIWM_ORCHESTRATION_ACTIVATION_ORIGIN_EXTERNAL):
            .external
        case UInt32(OMNIWM_ORCHESTRATION_ACTIVATION_ORIGIN_PROBE):
            .probe
        case UInt32(OMNIWM_ORCHESTRATION_ACTIVATION_ORIGIN_RETRY):
            .retry
        default:
            preconditionFailure("Unknown orchestration activation origin \(origin)")
        }
    }

    private static func decode(retryReason: UInt32) -> ActivationRetryReason {
        switch retryReason {
        case UInt32(OMNIWM_ORCHESTRATION_RETRY_REASON_MISSING_FOCUSED_WINDOW):
            .missingFocusedWindow
        case UInt32(OMNIWM_ORCHESTRATION_RETRY_REASON_PENDING_FOCUS_MISMATCH):
            .pendingFocusMismatch
        case UInt32(OMNIWM_ORCHESTRATION_RETRY_REASON_PENDING_FOCUS_UNMANAGED_TOKEN):
            .pendingFocusUnmanagedToken
        case UInt32(OMNIWM_ORCHESTRATION_RETRY_REASON_RETRY_EXHAUSTED):
            .retryExhausted
        default:
            preconditionFailure("Unknown orchestration retry reason \(retryReason)")
        }
    }

    private static func decode(monitorId: UInt32) -> Monitor.ID {
        Monitor.ID(displayId: monitorId)
    }
}
