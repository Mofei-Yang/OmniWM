import CoreGraphics
import Foundation

/// Swift-native implementation of the reduce algorithm that previously
/// lived in `Zig/omniwm_kernels/src/reconcile.zig`. Call sites in
/// `StateReducer` route here once M3.5 flips the cutover. No import of
/// `COmniWMKernels`; this file operates on native Swift types
/// (`WMEvent`, `WindowModel.Entry`, `FocusSessionSnapshot`, `Monitor`,
/// `ActionPlan`, `RestoreIntent`, `ReplacementCorrelation`).
enum NativeStateReducer {
    static func reduce(
        event: WMEvent,
        existingEntry: WindowModel.Entry?,
        currentSnapshot: ReconcileSnapshot,
        monitors: [Monitor],
        persistedHydration: PersistedHydrationMutation? = nil
    ) -> ActionPlan {
        var plan = ActionPlan()
        apply(
            event: event,
            existingEntry: existingEntry,
            currentSnapshot: currentSnapshot,
            monitors: monitors,
            persistedHydration: persistedHydration,
            into: &plan
        )
        return plan
    }

    static func restoreIntent(
        for entry: WindowModel.Entry,
        monitors: [Monitor]
    ) -> RestoreIntent {
        resolveRestoreIntent(entry: entry, monitors: monitors)
    }

    // MARK: - Event dispatch (implementation fills in each case — see M3.3.2+)
    private static func apply(
        event: WMEvent,
        existingEntry: WindowModel.Entry?,
        currentSnapshot: ReconcileSnapshot,
        monitors: [Monitor],
        persistedHydration: PersistedHydrationMutation?,
        into plan: inout ActionPlan
    ) {
        switch event {
        case let .windowAdmitted(_, workspaceId, monitorId, mode, _):
            applyWindowAdmitted(
                workspaceId: workspaceId,
                monitorId: monitorId,
                mode: mode,
                existingEntry: existingEntry,
                into: &plan
            )
        case let .windowRekeyed(from, to, workspaceId, monitorId, reason, _):
            applyWindowRekeyed(
                from: from,
                to: to,
                workspaceId: workspaceId,
                monitorId: monitorId,
                reason: reason,
                existingEntry: existingEntry,
                currentFocusSession: currentSnapshot.focusSession,
                into: &plan
            )
        case let .windowRemoved(token, _, _):
            applyWindowRemoved(
                token: token,
                currentFocusSession: currentSnapshot.focusSession,
                into: &plan
            )
        case let .workspaceAssigned(_, _, to, monitorId, _):
            applyWorkspaceAssigned(
                workspaceId: to,
                monitorId: monitorId,
                existingEntry: existingEntry,
                into: &plan
            )
        case let .windowModeChanged(_, workspaceId, monitorId, mode, _):
            applyWindowModeChanged(
                workspaceId: workspaceId,
                monitorId: monitorId,
                mode: mode,
                existingEntry: existingEntry,
                into: &plan
            )
        case let .floatingGeometryUpdated(_, workspaceId, referenceMonitorId, frame, restoreToFloating, _):
            applyFloatingGeometryUpdated(
                workspaceId: workspaceId,
                referenceMonitorId: referenceMonitorId,
                frame: frame,
                restoreToFloating: restoreToFloating,
                existingEntry: existingEntry,
                into: &plan
            )
        case let .hiddenStateChanged(_, workspaceId, monitorId, hiddenState, _):
            applyHiddenStateChanged(
                workspaceId: workspaceId,
                monitorId: monitorId,
                hiddenState: hiddenState,
                existingEntry: existingEntry,
                into: &plan
            )
        case let .nativeFullscreenTransition(_, workspaceId, monitorId, isActive, _):
            applyNativeFullscreenTransition(
                workspaceId: workspaceId,
                monitorId: monitorId,
                isActive: isActive,
                existingEntry: existingEntry,
                into: &plan
            )
        case let .managedReplacementMetadataChanged(_, workspaceId, monitorId, _):
            applyManagedReplacementMetadataChanged(
                workspaceId: workspaceId,
                monitorId: monitorId,
                existingEntry: existingEntry,
                into: &plan
            )
        case let .focusLeaseChanged(lease, _):
            applyFocusLeaseChanged(
                lease: lease,
                currentFocusSession: currentSnapshot.focusSession,
                into: &plan
            )
        case let .managedFocusRequested(token, workspaceId, monitorId, _):
            applyManagedFocusRequested(
                token: token,
                workspaceId: workspaceId,
                monitorId: monitorId,
                currentFocusSession: currentSnapshot.focusSession,
                into: &plan
            )
        case let .managedFocusConfirmed(token, _, _, appFullscreen, _):
            applyManagedFocusConfirmed(
                token: token,
                appFullscreen: appFullscreen,
                currentFocusSession: currentSnapshot.focusSession,
                into: &plan
            )
        case let .managedFocusCancelled(token, workspaceId, _):
            applyManagedFocusCancelled(
                token: token,
                workspaceId: workspaceId,
                currentFocusSession: currentSnapshot.focusSession,
                into: &plan
            )
        case let .nonManagedFocusChanged(active, appFullscreen, preserveFocusedToken, _):
            applyNonManagedFocusChanged(
                isActive: active,
                appFullscreen: appFullscreen,
                preserveFocusedToken: preserveFocusedToken,
                currentFocusSession: currentSnapshot.focusSession,
                into: &plan
            )
        case let .topologyChanged(displays, _):
            applyTopologyChanged(displays: displays, into: &plan)
        case .activeSpaceChanged:
            applyActiveSpaceChanged(into: &plan)
        case .systemSleep:
            applySystemSleep(into: &plan)
        case .systemWake:
            applySystemWake(into: &plan)
        }

        // Mirror post-switch block in reconcile.zig:
        // applyHydration overrides observed/desired/lifecycle if hydration present
        if let hydration = persistedHydration {
            applyHydration(hydration: hydration, existingEntry: existingEntry, into: &plan)
        }

        // deriveRestoreIntent is computed whenever existing_entry is non-null
        if let resolvedEntry = existingEntry {
            plan.restoreIntent = deriveRestoreIntent(
                entry: resolvedEntry,
                currentPlan: plan,
                monitors: monitors,
                hydration: persistedHydration
            )
        }
    }

    // MARK: - Per-event helpers (M3.3.2: 5 lifecycle-producing branches)

    // event_window_admitted:
    //   output.lifecycle_phase = lifecycleForMode(event.mode)
    //   output.observed_state  = baseObserved(existing, workspace, monitor)
    //   output.desired_state   = baseDesired(existing, workspace, monitor, mode)
    private static func applyWindowAdmitted(
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        mode: TrackedWindowMode,
        existingEntry: WindowModel.Entry?,
        into plan: inout ActionPlan
    ) {
        plan.lifecyclePhase = lifecycleForMode(mode)
        plan.observedState = baseObserved(entry: existingEntry, workspaceId: workspaceId, monitorId: monitorId)
        plan.desiredState = baseDesired(entry: existingEntry, workspaceId: workspaceId, monitorId: monitorId, mode: mode)
    }

    // event_window_rekeyed:
    //   lifecycle = .replacing
    //   observed  = baseObserved(existing, workspace, monitor)
    //   desired   = baseDesired(existing, workspace, monitor, effectiveMode(existing))
    //   replacement_correlation populated from event
    //   focus tokens remapped: secondary_token → token
    private static func applyWindowRekeyed(
        from previousToken: WindowToken,
        to nextToken: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        reason: ReplacementCorrelation.Reason,
        existingEntry: WindowModel.Entry?,
        currentFocusSession: FocusSessionSnapshot,
        into plan: inout ActionPlan
    ) {
        let mode = effectiveMode(entry: existingEntry)
        plan.lifecyclePhase = .replacing
        plan.observedState = baseObserved(entry: existingEntry, workspaceId: workspaceId, monitorId: monitorId)
        plan.desiredState = baseDesired(entry: existingEntry, workspaceId: workspaceId, monitorId: monitorId, mode: mode)
        plan.replacementCorrelation = ReplacementCorrelation(
            previousToken: previousToken,
            nextToken: nextToken,
            reason: reason,
            recordedAt: Date()
        )

        // Zig: remap focused_token and pending_managed_focus.token if they match secondary_token
        var next_focus = focusSessionFromInput(currentFocusSession)
        if let focused = next_focus.focusedToken, focused == previousToken {
            next_focus.focusedToken = nextToken
        }
        if let pending = next_focus.pendingManagedFocus.token, pending == previousToken {
            next_focus.pendingManagedFocus.token = nextToken
        }
        plan.focusSession = next_focus
    }

    // event_window_removed:
    //   lifecycle = .destroyed
    //   focus: clear focused_token if it matches event.token, clear pending if it matches
    private static func applyWindowRemoved(
        token: WindowToken,
        currentFocusSession: FocusSessionSnapshot,
        into plan: inout ActionPlan
    ) {
        plan.lifecyclePhase = .destroyed

        var next_focus = focusSessionFromInput(currentFocusSession)
        if let focused = next_focus.focusedToken, focused == token {
            next_focus.focusedToken = nil
            next_focus.isAppFullscreenActive = false
        }
        if let pending = next_focus.pendingManagedFocus.token, pending == token {
            next_focus.pendingManagedFocus = .empty
        }
        plan.focusSession = next_focus
    }

    // event_workspace_assigned:
    //   no lifecycle set
    //   observed = baseObserved(existing, workspace, monitor)
    //   desired  = baseDesired(existing, workspace, monitor, effectiveMode(existing))
    private static func applyWorkspaceAssigned(
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        existingEntry: WindowModel.Entry?,
        into plan: inout ActionPlan
    ) {
        let mode = effectiveMode(entry: existingEntry)
        plan.observedState = baseObserved(entry: existingEntry, workspaceId: workspaceId, monitorId: monitorId)
        plan.desiredState = baseDesired(entry: existingEntry, workspaceId: workspaceId, monitorId: monitorId, mode: mode)
    }

    // event_window_mode_changed:
    //   lifecycle = lifecycleForMode(event.mode)
    //   observed  = baseObserved(existing, workspace, monitor)
    //   desired   = baseDesired(existing, workspace, monitor, event.mode)
    private static func applyWindowModeChanged(
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        mode: TrackedWindowMode,
        existingEntry: WindowModel.Entry?,
        into plan: inout ActionPlan
    ) {
        plan.lifecyclePhase = lifecycleForMode(mode)
        plan.observedState = baseObserved(entry: existingEntry, workspaceId: workspaceId, monitorId: monitorId)
        plan.desiredState = baseDesired(entry: existingEntry, workspaceId: workspaceId, monitorId: monitorId, mode: mode)
    }

    // event_floating_geometry_updated:
    //   lifecycle = .floating
    //   observed  = baseObserved(existing, workspace, monitor); frame = event.frame
    //   desired   = baseDesired(existing, workspace, monitor, mode_floating);
    //               floating_frame = event.frame; rescue_eligible = event.restore_to_floating
    private static func applyFloatingGeometryUpdated(
        workspaceId: WorkspaceDescriptor.ID,
        referenceMonitorId: Monitor.ID?,
        frame: CGRect,
        restoreToFloating: Bool,
        existingEntry: WindowModel.Entry?,
        into plan: inout ActionPlan
    ) {
        plan.lifecyclePhase = .floating
        var observed = baseObserved(entry: existingEntry, workspaceId: workspaceId, monitorId: referenceMonitorId)
        observed.frame = frame
        plan.observedState = observed
        var desired = baseDesired(entry: existingEntry, workspaceId: workspaceId, monitorId: referenceMonitorId, mode: .floating)
        desired.floatingFrame = frame
        // Zig: desired_state.rescue_eligible = event.restore_to_floating (direct override, not OR)
        desired.rescueEligible = restoreToFloating
        plan.desiredState = desired
    }

    // event_hidden_state_changed:
    //   observed  = baseObserved(existing, workspace, monitor);
    //               is_visible = (hidden_state == hidden_state_visible)
    //   lifecycle = visible → lifecycleForMode(effectiveMode); hidden → .hidden; else → .offscreen
    //
    // Swift hiddenState mapping (mirrors StateReducer.encode(hiddenState:)):
    //   nil (visible)              → hidden_state_visible (0)
    //   HiddenState with no offscreenSide → hidden_state_hidden (1)
    //   HiddenState with offscreenSide    → else (2 or 3) → lifecycle_offscreen
    private static func applyHiddenStateChanged(
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        hiddenState: WindowModel.HiddenState?,
        existingEntry: WindowModel.Entry?,
        into plan: inout ActionPlan
    ) {
        var observed = baseObserved(entry: existingEntry, workspaceId: workspaceId, monitorId: monitorId)
        observed.isVisible = hiddenState == nil
        plan.observedState = observed
        if hiddenState == nil {
            // hidden_state_visible: lifecycle = lifecycleForMode(effectiveMode)
            plan.lifecyclePhase = lifecycleForMode(effectiveMode(entry: existingEntry))
        } else if hiddenState?.offscreenSide == nil {
            // hidden_state_hidden: lifecycle = .hidden
            plan.lifecyclePhase = .hidden
        } else {
            // offscreen (left/right): lifecycle = .offscreen
            plan.lifecyclePhase = .offscreen
        }
    }

    // event_native_fullscreen_transition:
    //   observed  = baseObserved(existing, workspace, monitor);
    //               is_native_fullscreen = event.is_active
    //   lifecycle = is_active ? .nativeFullscreen : lifecycleForMode(effectiveMode(existing))
    private static func applyNativeFullscreenTransition(
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        isActive: Bool,
        existingEntry: WindowModel.Entry?,
        into plan: inout ActionPlan
    ) {
        var observed = baseObserved(entry: existingEntry, workspaceId: workspaceId, monitorId: monitorId)
        observed.isNativeFullscreen = isActive
        plan.observedState = observed
        plan.lifecyclePhase = isActive ? .nativeFullscreen : lifecycleForMode(effectiveMode(entry: existingEntry))
    }

    // event_managed_replacement_metadata_changed:
    //   observed  = baseObserved(existing, workspace, monitor)
    //   desired   = baseDesired(existing, workspace, monitor, effectiveMode(existing))
    //   note      = "managed_replacement_metadata_changed"
    private static func applyManagedReplacementMetadataChanged(
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        existingEntry: WindowModel.Entry?,
        into plan: inout ActionPlan
    ) {
        let mode = effectiveMode(entry: existingEntry)
        plan.observedState = baseObserved(entry: existingEntry, workspaceId: workspaceId, monitorId: monitorId)
        plan.desiredState = baseDesired(entry: existingEntry, workspaceId: workspaceId, monitorId: monitorId, mode: mode)
        plan.notes.append("managed_replacement_metadata_changed")
    }

    // MARK: - Per-event helpers (M3.3.4: 5 focus-related branches)

    // event_focus_lease_changed:
    //   next_focus = focusSessionFromInput(focus_session)
    //   focus_lease_action = has_focus_lease ? SET_FROM_EVENT : CLEAR
    //   note = has_focus_lease ? note_focus_lease_set : note_focus_lease_cleared
    private static func applyFocusLeaseChanged(
        lease: FocusPolicyLease?,
        currentFocusSession: FocusSessionSnapshot,
        into plan: inout ActionPlan
    ) {
        var next_focus = focusSessionFromInput(currentFocusSession)
        if let lease {
            // focus_lease_action = SET_FROM_EVENT
            next_focus.focusLease = lease
            plan.notes = ["focus_lease=\(lease.owner.rawValue)", lease.reason].filter { !$0.isEmpty }
        } else {
            // focus_lease_action = CLEAR
            next_focus.focusLease = nil
            plan.notes = ["focus_lease=cleared"]
        }
        plan.focusSession = next_focus
    }

    // event_managed_focus_requested:
    //   next_focus = focusSessionFromInput(focus_session)
    //   next_focus.pending_managed_focus = { token, workspace_id, monitor_id }
    private static func applyManagedFocusRequested(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        currentFocusSession: FocusSessionSnapshot,
        into plan: inout ActionPlan
    ) {
        var next_focus = focusSessionFromInput(currentFocusSession)
        next_focus.pendingManagedFocus = PendingManagedFocusSnapshot(
            token: token,
            workspaceId: workspaceId,
            monitorId: monitorId
        )
        plan.focusSession = next_focus
    }

    // event_managed_focus_confirmed:
    //   next_focus = focusSessionFromInput(focus_session)
    //   next_focus.has_focused_token = 1; focused_token = event.token
    //   next_focus.pending_managed_focus = emptyPendingFocus()
    //   next_focus.is_non_managed_focus_active = 0
    //   next_focus.is_app_fullscreen_active = event.app_fullscreen
    private static func applyManagedFocusConfirmed(
        token: WindowToken,
        appFullscreen: Bool,
        currentFocusSession: FocusSessionSnapshot,
        into plan: inout ActionPlan
    ) {
        var next_focus = focusSessionFromInput(currentFocusSession)
        next_focus.focusedToken = token
        next_focus.pendingManagedFocus = .empty
        next_focus.isNonManagedFocusActive = false
        next_focus.isAppFullscreenActive = appFullscreen
        plan.focusSession = next_focus
    }

    // event_managed_focus_cancelled:
    //   next_focus = focusSessionFromInput(focus_session)
    //   matches_token = has_secondary_token ? (pending.has_token && pending.token == event.secondary_token) : true
    //   matches_workspace = has_workspace_id ? (pending.has_workspace_id && pending.workspace_id == event.workspace_id) : true
    //   if matches_token && matches_workspace: pending_managed_focus = emptyPendingFocus()
    //
    // Swift mapping: event.managedFocusCancelled carries (token: WindowToken?, workspaceId: UUID?)
    //   token == nil   → has_secondary_token = 0  → matches_token = true (unconditional)
    //   token non-nil  → has_secondary_token = 1  → compare with pending.token
    //   workspaceId == nil  → has_workspace_id = 0  → matches_workspace = true (unconditional)
    //   workspaceId non-nil → has_workspace_id = 1  → compare with pending.workspaceId
    private static func applyManagedFocusCancelled(
        token: WindowToken?,
        workspaceId: WorkspaceDescriptor.ID?,
        currentFocusSession: FocusSessionSnapshot,
        into plan: inout ActionPlan
    ) {
        var next_focus = focusSessionFromInput(currentFocusSession)
        let matches_token: Bool
        if let secondary_token = token {
            matches_token = next_focus.pendingManagedFocus.token == secondary_token
        } else {
            matches_token = true
        }
        let matches_workspace: Bool
        if let event_workspace = workspaceId {
            matches_workspace = next_focus.pendingManagedFocus.workspaceId == event_workspace
        } else {
            matches_workspace = true
        }
        if matches_token && matches_workspace {
            next_focus.pendingManagedFocus = .empty
        }
        plan.focusSession = next_focus
    }

    // event_non_managed_focus_changed:
    //   next_focus = focusSessionFromInput(focus_session)
    //   if event.is_active != 0 && event.preserve_focused_token == 0: has_focused_token = 0
    //   next_focus.pending_managed_focus = emptyPendingFocus()
    //   next_focus.is_non_managed_focus_active = event.is_active
    //   next_focus.is_app_fullscreen_active = event.app_fullscreen
    private static func applyNonManagedFocusChanged(
        isActive: Bool,
        appFullscreen: Bool,
        preserveFocusedToken: Bool,
        currentFocusSession: FocusSessionSnapshot,
        into plan: inout ActionPlan
    ) {
        var next_focus = focusSessionFromInput(currentFocusSession)
        if isActive && !preserveFocusedToken {
            next_focus.focusedToken = nil
        }
        next_focus.pendingManagedFocus = .empty
        next_focus.isNonManagedFocusActive = isActive
        next_focus.isAppFullscreenActive = appFullscreen
        plan.focusSession = next_focus
    }

    // MARK: - Per-event helpers (M3.3.5: 4 topology/space/system note-only branches)

    // event_topology_changed:
    //   output.note_code = note_topology_changed
    //   note string = "topology=\(displays.count)"  (decoded by StateReducer.decodeNotes)
    private static func applyTopologyChanged(
        displays: [DisplayFingerprint],
        into plan: inout ActionPlan
    ) {
        plan.notes.append("topology=\(displays.count)")
    }

    // event_active_space_changed:
    //   output.note_code = note_active_space_changed
    //   note string = "active_space_changed"
    private static func applyActiveSpaceChanged(into plan: inout ActionPlan) {
        plan.notes.append("active_space_changed")
    }

    // event_system_sleep:
    //   output.note_code = note_system_sleep
    //   note string = "system_sleep"
    private static func applySystemSleep(into plan: inout ActionPlan) {
        plan.notes.append("system_sleep")
    }

    // event_system_wake:
    //   output.note_code = note_system_wake
    //   note string = "system_wake"
    private static func applySystemWake(into plan: inout ActionPlan) {
        plan.notes.append("system_wake")
    }

    // MARK: - Restore intent (see M3.4)
    //
    // Mirrors the Zig `omniwm_reconcile_restore_intent` entrypoint (reconcile.zig:655-678):
    // constructs a SimulatedEntry directly from the entry's raw fields and passes it to
    // deriveRestoreIntent — no plan-output merging, no hydration.
    private static func resolveRestoreIntent(
        entry: WindowModel.Entry,
        monitors: [Monitor]
    ) -> RestoreIntent {
        return buildRestoreIntent(
            workspaceId: entry.workspaceId,
            mode: entry.mode,
            observedState: entry.observedState,
            desiredState: entry.desiredState,
            floatingState: entry.floatingState,
            monitors: monitors
        )
    }

    // MARK: - Helpers mirroring Zig helper fns

    // lifecycleForMode: mode_floating → .floating, else → .tiled
    private static func lifecycleForMode(_ mode: TrackedWindowMode) -> WindowLifecyclePhase {
        mode == .floating ? .floating : .tiled
    }

    // effectiveMode: existing?.mode ?? .tiling
    private static func effectiveMode(entry: WindowModel.Entry?) -> TrackedWindowMode {
        entry?.mode ?? .tiling
    }

    // Equivalent of Zig's `focus_lease_action = keep_existing` — the Swift
    // snapshot carries no separate lease-action field, so preserving the
    // existing `focusLease` (by leaving the snapshot unchanged) achieves the
    // same outcome. If a future branch needs to change lease semantics it
    // must mutate `focusLease` directly; do not add lease copying here.
    private static func focusSessionFromInput(_ session: FocusSessionSnapshot) -> FocusSessionSnapshot {
        session
    }

    // initialObserved: mirrors Zig initialObserved — workspace set, monitor optional,
    //   is_visible=1, has_ax_reference=1, everything else zeroed
    private static func initialObserved(
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?
    ) -> ObservedWindowState {
        ObservedWindowState(
            frame: nil,
            workspaceId: workspaceId,
            monitorId: monitorId,
            isVisible: true,
            isFocused: false,
            hasAXReference: true,
            isNativeFullscreen: false
        )
    }

    // initialDesired: mirrors Zig initialDesired — workspace set, monitor optional,
    //   disposition=mode, rescue_eligible=(mode==floating)
    private static func initialDesired(
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        mode: TrackedWindowMode
    ) -> DesiredWindowState {
        DesiredWindowState(
            workspaceId: workspaceId,
            monitorId: monitorId,
            disposition: mode,
            floatingFrame: nil,
            rescueEligible: mode == .floating
        )
    }

    // baseObserved: if entry present, copy it, then overwrite workspace/monitor/hasAXRef;
    //   else use initialObserved.
    //   Mirrors Zig baseObserved.
    private static func baseObserved(
        entry: WindowModel.Entry?,
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?
    ) -> ObservedWindowState {
        var state: ObservedWindowState
        if let resolved = entry {
            state = resolved.observedState
        } else {
            state = initialObserved(workspaceId: workspaceId, monitorId: monitorId)
        }
        state.workspaceId = workspaceId
        if let monitorId {
            state.monitorId = monitorId
        }
        state.hasAXReference = true
        return state
    }

    // baseDesired: if entry present, copy it, then overwrite workspace/monitor/disposition;
    //   rescue_eligible is OR'd: (mode==floating || existing rescue_eligible)
    //   Mirrors Zig baseDesired.
    private static func baseDesired(
        entry: WindowModel.Entry?,
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        mode: TrackedWindowMode
    ) -> DesiredWindowState {
        var state: DesiredWindowState
        if let resolved = entry {
            state = resolved.desiredState
        } else {
            state = initialDesired(workspaceId: workspaceId, monitorId: monitorId, mode: mode)
        }
        state.workspaceId = workspaceId
        if let monitorId {
            state.monitorId = monitorId
        }
        state.disposition = mode
        // Zig: rescue_eligible = @intFromBool(mode == mode_floating or state.rescue_eligible != 0)
        state.rescueEligible = mode == .floating || state.rescueEligible
        return state
    }

    // MARK: - applyHydration — mirrors Zig applyHydration
    // Overwrites observed/desired/lifecycle from the persisted hydration mutation.
    private static func applyHydration(
        hydration: PersistedHydrationMutation,
        existingEntry: WindowModel.Entry?,
        into plan: inout ActionPlan
    ) {
        // observed: start from plan.observedState if set, else existing, else initial
        var observed: ObservedWindowState
        if let existing = plan.observedState {
            observed = existing
        } else if let resolved = existingEntry {
            observed = resolved.observedState
        } else {
            observed = initialObserved(workspaceId: hydration.workspaceId, monitorId: hydration.monitorId)
        }
        observed.workspaceId = hydration.workspaceId
        if let monitorId = hydration.monitorId {
            observed.monitorId = monitorId
        }
        observed.hasAXReference = true
        plan.observedState = observed

        // desired: start from plan.desiredState if set, else existing, else initial
        var desired: DesiredWindowState
        if let existing = plan.desiredState {
            desired = existing
        } else if let resolved = existingEntry {
            desired = resolved.desiredState
        } else {
            desired = initialDesired(
                workspaceId: hydration.workspaceId,
                monitorId: hydration.monitorId,
                mode: hydration.targetMode
            )
        }
        desired.workspaceId = hydration.workspaceId
        if let monitorId = hydration.monitorId {
            desired.monitorId = monitorId
        }
        desired.disposition = hydration.targetMode
        if let floatingFrame = hydration.floatingFrame {
            desired.floatingFrame = floatingFrame
            desired.rescueEligible = true
        } else if hydration.targetMode == .floating {
            desired.rescueEligible = true
        }
        plan.desiredState = desired

        // lifecycle
        plan.lifecyclePhase = lifecycleForMode(hydration.targetMode)
    }

    // MARK: - deriveRestoreIntent — mirrors Zig deriveRestoreIntent + simulatedEntry logic
    // This is the post-switch call: builds a SimulatedEntry then derives the restore intent.
    //
    // Zig builds a SimulatedEntry (reconcile.zig, ~line 378) before calling
    // deriveRestoreIntent. Swift inlines that projection here — the hydration
    // branches below carry the same semantics as simulatedEntry + deriveRestoreIntent
    // combined.
    private static func deriveRestoreIntent(
        entry: WindowModel.Entry,
        currentPlan: ActionPlan,
        monitors: [Monitor],
        hydration: PersistedHydrationMutation?
    ) -> RestoreIntent {
        // simulatedEntry: merge existing entry with plan output (and optional hydration)
        let workspaceId: WorkspaceDescriptor.ID
        let mode: TrackedWindowMode
        let observedState: ObservedWindowState
        let desiredState: DesiredWindowState
        var floatingState: WindowModel.FloatingState? = entry.floatingState

        if let hydration {
            workspaceId = hydration.workspaceId
            mode = hydration.targetMode
            observedState = currentPlan.observedState ?? entry.observedState
            desiredState = currentPlan.desiredState ?? entry.desiredState
            // apply hydration floating frame into floating state if present
            if let floatingFrame = hydration.floatingFrame {
                let visibleFrame = visibleFrameForHydration(monitors: monitors, hydration: hydration)
                let normOrigin = normalizedFloatingOrigin(frame: floatingFrame, visibleFrame: visibleFrame)
                floatingState = WindowModel.FloatingState(
                    lastFrame: floatingFrame,
                    normalizedOrigin: normOrigin,
                    referenceMonitorId: hydration.monitorId,
                    restoreToFloating: true
                )
            }
        } else {
            workspaceId = entry.workspaceId
            mode = entry.mode
            observedState = currentPlan.observedState ?? entry.observedState
            desiredState = currentPlan.desiredState ?? entry.desiredState
        }

        return buildRestoreIntent(
            workspaceId: workspaceId,
            mode: mode,
            observedState: observedState,
            desiredState: desiredState,
            floatingState: floatingState,
            monitors: monitors
        )
    }

    // MARK: - buildRestoreIntent — mirrors Zig deriveRestoreIntent(state, monitors)
    private static func buildRestoreIntent(
        workspaceId: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode,
        observedState: ObservedWindowState,
        desiredState: DesiredWindowState,
        floatingState: WindowModel.FloatingState?,
        monitors: [Monitor]
    ) -> RestoreIntent {
        // Preferred monitor: desired → observed → floating.referenceMonitorId
        var preferred_index: Int? = nil
        if let monitorId = desiredState.monitorId {
            preferred_index = findMonitorIndex(monitors: monitors, monitorId: monitorId)
        }
        if preferred_index == nil, let monitorId = observedState.monitorId {
            preferred_index = findMonitorIndex(monitors: monitors, monitorId: monitorId)
        }
        if preferred_index == nil, let fs = floatingState, let refId = fs.referenceMonitorId {
            preferred_index = findMonitorIndex(monitors: monitors, monitorId: refId)
        }

        let preferredMonitor: DisplayFingerprint?
        if let idx = preferred_index, idx < monitors.count {
            preferredMonitor = DisplayFingerprint(monitor: monitors[idx])
        } else {
            preferredMonitor = nil
        }

        // floating frame: desired.floatingFrame → floatingState.lastFrame
        let floatingFrame: CGRect?
        if let ff = desiredState.floatingFrame {
            floatingFrame = ff
        } else if let fs = floatingState {
            floatingFrame = fs.lastFrame
        } else {
            floatingFrame = nil
        }

        // normalized floating origin: from floatingState only if has_normalized_origin
        let normalizedFloatingOrigin: CGPoint?
        if let fs = floatingState, let normOrigin = fs.normalizedOrigin {
            normalizedFloatingOrigin = normOrigin
        } else {
            normalizedFloatingOrigin = nil
        }

        // restore_to_floating: if floatingState present use its flag, else mode == floating
        let restoreToFloating: Bool
        if let fs = floatingState {
            restoreToFloating = fs.restoreToFloating
        } else {
            restoreToFloating = mode == .floating
        }

        // rescue_eligible: desired.rescueEligible || floatingState?.restoreToFloating
        let rescueEligible: Bool
        if desiredState.rescueEligible {
            rescueEligible = true
        } else if let fs = floatingState, fs.restoreToFloating {
            rescueEligible = true
        } else {
            rescueEligible = false
        }

        return RestoreIntent(
            topologyProfile: TopologyProfile(monitors: monitors),
            workspaceId: workspaceId,
            preferredMonitor: preferredMonitor,
            floatingFrame: floatingFrame,
            normalizedFloatingOrigin: normalizedFloatingOrigin,
            restoreToFloating: restoreToFloating,
            rescueEligible: rescueEligible
        )
    }

    // MARK: - Utility helpers

    private static func findMonitorIndex(monitors: [Monitor], monitorId: Monitor.ID) -> Int? {
        monitors.firstIndex { $0.id == monitorId }
    }

    private static func normalizedFloatingOrigin(frame: CGRect, visibleFrame: CGRect) -> CGPoint {
        let availableWidth = max(1.0, visibleFrame.width - frame.width)
        let availableHeight = max(1.0, visibleFrame.height - frame.height)
        let normalizedX = (frame.minX - visibleFrame.minX) / availableWidth
        let normalizedY = (frame.minY - visibleFrame.minY) / availableHeight
        return CGPoint(
            x: min(max(normalizedX, 0), 1),
            y: min(max(normalizedY, 0), 1)
        )
    }

    private static func visibleFrameForHydration(
        monitors: [Monitor],
        hydration: PersistedHydrationMutation
    ) -> CGRect {
        if let monitorId = hydration.monitorId,
           let idx = findMonitorIndex(monitors: monitors, monitorId: monitorId)
        {
            return monitors[idx].visibleFrame
        }
        return hydration.floatingFrame ?? .zero
    }
}
