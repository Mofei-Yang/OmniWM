import COmniWMKernels
import Foundation

@MainActor
enum WorkspaceNavigationKernel {
    enum Operation {
        case focusMonitorCyclic
        case focusMonitorLast
        case swapWorkspaceWithMonitor
        case switchWorkspaceExplicit
        case switchWorkspaceRelative
        case focusWorkspaceAnywhere
        case workspaceBackAndForth
        case moveWindowAdjacent
        case moveWindowExplicit
        case moveColumnAdjacent
        case moveColumnExplicit
        case moveWindowToWorkspaceOnMonitor
        case moveWindowHandle

        var rawValue: UInt32 {
            switch self {
            case .focusMonitorCyclic: UInt32(OMNIWM_WORKSPACE_NAV_OPERATION_FOCUS_MONITOR_CYCLIC)
            case .focusMonitorLast: UInt32(OMNIWM_WORKSPACE_NAV_OPERATION_FOCUS_MONITOR_LAST)
            case .swapWorkspaceWithMonitor: UInt32(OMNIWM_WORKSPACE_NAV_OPERATION_SWAP_WORKSPACE_WITH_MONITOR)
            case .switchWorkspaceExplicit: UInt32(OMNIWM_WORKSPACE_NAV_OPERATION_SWITCH_WORKSPACE_EXPLICIT)
            case .switchWorkspaceRelative: UInt32(OMNIWM_WORKSPACE_NAV_OPERATION_SWITCH_WORKSPACE_RELATIVE)
            case .focusWorkspaceAnywhere: UInt32(OMNIWM_WORKSPACE_NAV_OPERATION_FOCUS_WORKSPACE_ANYWHERE)
            case .workspaceBackAndForth: UInt32(OMNIWM_WORKSPACE_NAV_OPERATION_WORKSPACE_BACK_AND_FORTH)
            case .moveWindowAdjacent: UInt32(OMNIWM_WORKSPACE_NAV_OPERATION_MOVE_WINDOW_ADJACENT)
            case .moveWindowExplicit: UInt32(OMNIWM_WORKSPACE_NAV_OPERATION_MOVE_WINDOW_EXPLICIT)
            case .moveColumnAdjacent: UInt32(OMNIWM_WORKSPACE_NAV_OPERATION_MOVE_COLUMN_ADJACENT)
            case .moveColumnExplicit: UInt32(OMNIWM_WORKSPACE_NAV_OPERATION_MOVE_COLUMN_EXPLICIT)
            case .moveWindowToWorkspaceOnMonitor: UInt32(OMNIWM_WORKSPACE_NAV_OPERATION_MOVE_WINDOW_TO_WORKSPACE_ON_MONITOR)
            case .moveWindowHandle: UInt32(OMNIWM_WORKSPACE_NAV_OPERATION_MOVE_WINDOW_HANDLE)
            }
        }
    }

    enum Outcome {
        case noop
        case execute
        case invalidTarget
        case blocked

        init(rawValue: UInt32) {
            switch rawValue {
            case UInt32(OMNIWM_WORKSPACE_NAV_OUTCOME_EXECUTE): self = .execute
            case UInt32(OMNIWM_WORKSPACE_NAV_OUTCOME_INVALID_TARGET): self = .invalidTarget
            case UInt32(OMNIWM_WORKSPACE_NAV_OUTCOME_BLOCKED): self = .blocked
            default: self = .noop
            }
        }
    }

    enum FocusAction {
        case none
        case workspaceHandoff
        case resolveTargetIfPresent
        case subject
        case recoverSource

        init(rawValue: UInt32) {
            switch rawValue {
            case UInt32(OMNIWM_WORKSPACE_NAV_FOCUS_WORKSPACE_HANDOFF): self = .workspaceHandoff
            case UInt32(OMNIWM_WORKSPACE_NAV_FOCUS_RESOLVE_TARGET_IF_PRESENT): self = .resolveTargetIfPresent
            case UInt32(OMNIWM_WORKSPACE_NAV_FOCUS_SUBJECT): self = .subject
            case UInt32(OMNIWM_WORKSPACE_NAV_FOCUS_RECOVER_SOURCE): self = .recoverSource
            default: self = .none
            }
        }
    }

    enum Subject {
        case none
        case window(WindowToken)
        case column(WindowToken)
    }

    struct Intent {
        var operation: Operation
        var direction: Direction = .right
        var currentWorkspaceId: WorkspaceDescriptor.ID?
        var sourceWorkspaceId: WorkspaceDescriptor.ID?
        var targetWorkspaceId: WorkspaceDescriptor.ID?
        var currentMonitorId: Monitor.ID?
        var previousMonitorId: Monitor.ID?
        var subjectToken: WindowToken?
        var focusedToken: WindowToken?
        var selectedToken: WindowToken?
        var wrapAround = false
        var followFocus = false
    }

    struct Plan {
        var outcome: Outcome
        var subject: Subject
        var focusAction: FocusAction
        var sourceWorkspaceId: WorkspaceDescriptor.ID?
        var targetWorkspaceId: WorkspaceDescriptor.ID?
        var sourceMonitorId: Monitor.ID?
        var targetMonitorId: Monitor.ID?
        var saveWorkspaceIds: [WorkspaceDescriptor.ID]
        var affectedWorkspaceIds: Set<WorkspaceDescriptor.ID>
        var affectedMonitorIds: [Monitor.ID]
        var shouldActivateTargetWorkspace: Bool
        var shouldSetInteractionMonitor: Bool
        var shouldSyncMonitorsToNiri: Bool
        var shouldHideFocusBorder: Bool
        var shouldCommitWorkspaceTransition: Bool
    }

    static func plan(
        controller: WMController,
        intent: Intent
    ) -> Plan {
        let manager = controller.workspaceManager

        var rawMonitors = ContiguousArray<omniwm_workspace_navigation_monitor>()
        rawMonitors.reserveCapacity(manager.monitors.count)
        for monitor in manager.monitors {
            let activeWorkspaceId = manager.activeWorkspace(on: monitor.id)?.id
            let previousWorkspaceId = manager.previousWorkspace(on: monitor.id)?.id
            rawMonitors.append(
                omniwm_workspace_navigation_monitor(
                    monitor_id: monitor.id.displayId,
                    frame_min_x: monitor.frame.minX,
                    frame_max_y: monitor.frame.maxY,
                    center_x: monitor.frame.midX,
                    center_y: monitor.frame.midY,
                    active_workspace_id: activeWorkspaceId.map(encode(uuid:)) ?? zeroUUID(),
                    previous_workspace_id: previousWorkspaceId.map(encode(uuid:)) ?? zeroUUID(),
                    has_active_workspace_id: activeWorkspaceId == nil ? 0 : 1,
                    has_previous_workspace_id: previousWorkspaceId == nil ? 0 : 1
                )
            )
        }

        var rawWorkspaces = ContiguousArray<omniwm_workspace_navigation_workspace>()
        rawWorkspaces.reserveCapacity(manager.workspaces.count)
        for workspace in manager.workspaces {
            let monitorId = manager.monitorId(for: workspace.id)
            let layoutKind = rawLayoutKind(
                controller.settings.layoutType(for: workspace.name)
            )
            let numericName = Int32(exactly: Int(workspace.name) ?? -1) ?? -1
            rawWorkspaces.append(
                omniwm_workspace_navigation_workspace(
                    workspace_id: encode(uuid: workspace.id),
                    monitor_id: monitorId?.displayId ?? 0,
                    layout_kind: layoutKind,
                    numeric_name: numericName,
                    has_monitor_id: monitorId == nil ? 0 : 1,
                    has_numeric_name: Int(workspace.name) == nil ? 0 : 1,
                    is_empty: manager.entries(in: workspace.id).isEmpty ? 1 : 0
                )
            )
        }

        var rawInput = omniwm_workspace_navigation_input(
            operation: intent.operation.rawValue,
            direction: rawDirection(intent.direction),
            current_workspace_id: intent.currentWorkspaceId.map(encode(uuid:)) ?? zeroUUID(),
            source_workspace_id: intent.sourceWorkspaceId.map(encode(uuid:)) ?? zeroUUID(),
            target_workspace_id: intent.targetWorkspaceId.map(encode(uuid:)) ?? zeroUUID(),
            current_monitor_id: intent.currentMonitorId?.displayId ?? 0,
            previous_monitor_id: intent.previousMonitorId?.displayId ?? 0,
            subject_token: intent.subjectToken.map(encode(token:)) ?? zeroToken(),
            focused_token: intent.focusedToken.map(encode(token:)) ?? zeroToken(),
            selected_token: intent.selectedToken.map(encode(token:)) ?? zeroToken(),
            has_current_workspace_id: intent.currentWorkspaceId == nil ? 0 : 1,
            has_source_workspace_id: intent.sourceWorkspaceId == nil ? 0 : 1,
            has_target_workspace_id: intent.targetWorkspaceId == nil ? 0 : 1,
            has_current_monitor_id: intent.currentMonitorId == nil ? 0 : 1,
            has_previous_monitor_id: intent.previousMonitorId == nil ? 0 : 1,
            has_subject_token: intent.subjectToken == nil ? 0 : 1,
            has_focused_token: intent.focusedToken == nil ? 0 : 1,
            has_selected_token: intent.selectedToken == nil ? 0 : 1,
            wrap_around: intent.wrapAround ? 1 : 0,
            follow_focus: intent.followFocus ? 1 : 0
        )

        var saveWorkspaceIds = ContiguousArray(repeating: zeroUUID(), count: 4)
        var affectedWorkspaceIds = ContiguousArray(repeating: zeroUUID(), count: 4)
        var affectedMonitorIds = ContiguousArray(repeating: UInt32.zero, count: 4)

        var rawOutput = omniwm_workspace_navigation_output(
            outcome: 0,
            subject_kind: 0,
            focus_action: 0,
            source_workspace_id: zeroUUID(),
            target_workspace_id: zeroUUID(),
            source_monitor_id: 0,
            target_monitor_id: 0,
            subject_token: zeroToken(),
            save_workspace_ids: nil,
            save_workspace_capacity: saveWorkspaceIds.count,
            save_workspace_count: 0,
            affected_workspace_ids: nil,
            affected_workspace_capacity: affectedWorkspaceIds.count,
            affected_workspace_count: 0,
            affected_monitor_ids: nil,
            affected_monitor_capacity: affectedMonitorIds.count,
            affected_monitor_count: 0,
            has_source_workspace_id: 0,
            has_target_workspace_id: 0,
            has_source_monitor_id: 0,
            has_target_monitor_id: 0,
            has_subject_token: 0,
            should_activate_target_workspace: 0,
            should_set_interaction_monitor: 0,
            should_sync_monitors_to_niri: 0,
            should_hide_focus_border: 0,
            should_commit_workspace_transition: 0
        )

        let status = rawMonitors.withUnsafeBufferPointer { monitorBuffer in
            rawWorkspaces.withUnsafeBufferPointer { workspaceBuffer in
                saveWorkspaceIds.withUnsafeMutableBufferPointer { saveBuffer in
                    affectedWorkspaceIds.withUnsafeMutableBufferPointer { affectedWorkspaceBuffer in
                        affectedMonitorIds.withUnsafeMutableBufferPointer { affectedMonitorBuffer in
                            rawOutput.save_workspace_ids = saveBuffer.baseAddress
                            rawOutput.affected_workspace_ids = affectedWorkspaceBuffer.baseAddress
                            rawOutput.affected_monitor_ids = affectedMonitorBuffer.baseAddress
                            return withUnsafeMutablePointer(to: &rawInput) { inputPointer in
                                withUnsafeMutablePointer(to: &rawOutput) { outputPointer in
                                    omniwm_workspace_navigation_plan(
                                        inputPointer,
                                        monitorBuffer.baseAddress,
                                        monitorBuffer.count,
                                        workspaceBuffer.baseAddress,
                                        workspaceBuffer.count,
                                        outputPointer
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }

        precondition(
            status == OMNIWM_KERNELS_STATUS_OK,
            "omniwm_workspace_navigation_plan returned \(status)"
        )

        return decode(
            rawOutput: rawOutput,
            saveWorkspaceIds: Array(saveWorkspaceIds.prefix(rawOutput.save_workspace_count)),
            affectedWorkspaceIds: Array(affectedWorkspaceIds.prefix(rawOutput.affected_workspace_count)),
            affectedMonitorIds: Array(affectedMonitorIds.prefix(rawOutput.affected_monitor_count))
        )
    }

    static func selectedToken(
        controller: WMController,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> WindowToken? {
        guard let engine = controller.niriEngine else { return nil }
        let state = controller.workspaceManager.niriViewportState(for: workspaceId)
        guard let selectedNodeId = state.selectedNodeId,
              let node = engine.findNode(by: selectedNodeId) as? NiriWindow
        else {
            return nil
        }
        return node.token
    }

    private static func decode(
        rawOutput: omniwm_workspace_navigation_output,
        saveWorkspaceIds: [omniwm_uuid],
        affectedWorkspaceIds: [omniwm_uuid],
        affectedMonitorIds: [UInt32]
    ) -> Plan {
        let subject: Subject = if rawOutput.has_subject_token == 0 {
            .none
        } else if rawOutput.subject_kind == UInt32(OMNIWM_WORKSPACE_NAV_SUBJECT_COLUMN) {
            .column(decode(token: rawOutput.subject_token))
        } else {
            .window(decode(token: rawOutput.subject_token))
        }

        return Plan(
            outcome: Outcome(rawValue: rawOutput.outcome),
            subject: subject,
            focusAction: FocusAction(rawValue: rawOutput.focus_action),
            sourceWorkspaceId: rawOutput.has_source_workspace_id == 0 ? nil : decode(uuid: rawOutput.source_workspace_id),
            targetWorkspaceId: rawOutput.has_target_workspace_id == 0 ? nil : decode(uuid: rawOutput.target_workspace_id),
            sourceMonitorId: rawOutput.has_source_monitor_id == 0 ? nil : Monitor.ID(displayId: rawOutput.source_monitor_id),
            targetMonitorId: rawOutput.has_target_monitor_id == 0 ? nil : Monitor.ID(displayId: rawOutput.target_monitor_id),
            saveWorkspaceIds: saveWorkspaceIds.map(decode(uuid:)),
            affectedWorkspaceIds: Set(affectedWorkspaceIds.map(decode(uuid:))),
            affectedMonitorIds: affectedMonitorIds.map { Monitor.ID(displayId: $0) },
            shouldActivateTargetWorkspace: rawOutput.should_activate_target_workspace != 0,
            shouldSetInteractionMonitor: rawOutput.should_set_interaction_monitor != 0,
            shouldSyncMonitorsToNiri: rawOutput.should_sync_monitors_to_niri != 0,
            shouldHideFocusBorder: rawOutput.should_hide_focus_border != 0,
            shouldCommitWorkspaceTransition: rawOutput.should_commit_workspace_transition != 0
        )
    }

    private static func rawDirection(_ direction: Direction) -> UInt32 {
        switch direction {
        case .left: UInt32(OMNIWM_NIRI_TOPOLOGY_DIRECTION_LEFT)
        case .right: UInt32(OMNIWM_NIRI_TOPOLOGY_DIRECTION_RIGHT)
        case .up: UInt32(OMNIWM_NIRI_TOPOLOGY_DIRECTION_UP)
        case .down: UInt32(OMNIWM_NIRI_TOPOLOGY_DIRECTION_DOWN)
        }
    }

    private static func rawLayoutKind(_ layoutType: LayoutType) -> UInt32 {
        switch layoutType {
        case .defaultLayout: UInt32(OMNIWM_WORKSPACE_NAV_LAYOUT_DEFAULT)
        case .niri: UInt32(OMNIWM_WORKSPACE_NAV_LAYOUT_NIRI)
        case .dwindle: UInt32(OMNIWM_WORKSPACE_NAV_LAYOUT_DWINDLE)
        }
    }

    private static func encode(uuid: UUID) -> omniwm_uuid {
        let bytes = Array(withUnsafeBytes(of: uuid.uuid) { $0 })
        let high = bytes[0 ..< 8].reduce(UInt64.zero) { ($0 << 8) | UInt64($1) }
        let low = bytes[8 ..< 16].reduce(UInt64.zero) { ($0 << 8) | UInt64($1) }
        return omniwm_uuid(high: high, low: low)
    }

    private static func decode(uuid: omniwm_uuid) -> UUID {
        let b0 = UInt8((uuid.high >> 56) & 0xff)
        let b1 = UInt8((uuid.high >> 48) & 0xff)
        let b2 = UInt8((uuid.high >> 40) & 0xff)
        let b3 = UInt8((uuid.high >> 32) & 0xff)
        let b4 = UInt8((uuid.high >> 24) & 0xff)
        let b5 = UInt8((uuid.high >> 16) & 0xff)
        let b6 = UInt8((uuid.high >> 8) & 0xff)
        let b7 = UInt8(uuid.high & 0xff)
        let b8 = UInt8((uuid.low >> 56) & 0xff)
        let b9 = UInt8((uuid.low >> 48) & 0xff)
        let b10 = UInt8((uuid.low >> 40) & 0xff)
        let b11 = UInt8((uuid.low >> 32) & 0xff)
        let b12 = UInt8((uuid.low >> 24) & 0xff)
        let b13 = UInt8((uuid.low >> 16) & 0xff)
        let b14 = UInt8((uuid.low >> 8) & 0xff)
        let b15 = UInt8(uuid.low & 0xff)
        return UUID(uuid: (b0, b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12, b13, b14, b15))
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
}
