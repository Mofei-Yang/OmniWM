import COmniWMKernels
import Foundation
import Testing

private func makeWorkspaceNavigationUUID(high: UInt64, low: UInt64) -> omniwm_uuid {
    omniwm_uuid(high: high, low: low)
}

private func makeWorkspaceNavigationToken(
    pid: Int32,
    windowId: Int64
) -> omniwm_window_token {
    omniwm_window_token(pid: pid, window_id: windowId)
}

private func makeWorkspaceNavigationInput(
    operation: UInt32,
    direction: UInt32 = UInt32(OMNIWM_NIRI_TOPOLOGY_DIRECTION_RIGHT),
    currentWorkspace: omniwm_uuid? = nil,
    sourceWorkspace: omniwm_uuid? = nil,
    targetWorkspace: omniwm_uuid? = nil,
    currentMonitorId: UInt32? = nil,
    previousMonitorId: UInt32? = nil,
    subject: omniwm_window_token? = nil,
    focused: omniwm_window_token? = nil,
    selected: omniwm_window_token? = nil,
    wrapAround: Bool = false,
    followFocus: Bool = false
) -> omniwm_workspace_navigation_input {
    omniwm_workspace_navigation_input(
        operation: operation,
        direction: direction,
        current_workspace_id: currentWorkspace ?? omniwm_uuid(),
        source_workspace_id: sourceWorkspace ?? omniwm_uuid(),
        target_workspace_id: targetWorkspace ?? omniwm_uuid(),
        current_monitor_id: currentMonitorId ?? 0,
        previous_monitor_id: previousMonitorId ?? 0,
        subject_token: subject ?? omniwm_window_token(),
        focused_token: focused ?? omniwm_window_token(),
        selected_token: selected ?? omniwm_window_token(),
        has_current_workspace_id: currentWorkspace == nil ? 0 : 1,
        has_source_workspace_id: sourceWorkspace == nil ? 0 : 1,
        has_target_workspace_id: targetWorkspace == nil ? 0 : 1,
        has_current_monitor_id: currentMonitorId == nil ? 0 : 1,
        has_previous_monitor_id: previousMonitorId == nil ? 0 : 1,
        has_subject_token: subject == nil ? 0 : 1,
        has_focused_token: focused == nil ? 0 : 1,
        has_selected_token: selected == nil ? 0 : 1,
        wrap_around: wrapAround ? 1 : 0,
        follow_focus: followFocus ? 1 : 0
    )
}

private func makeWorkspaceNavigationMonitor(
    id: UInt32,
    minX: Double,
    maxY: Double,
    centerX: Double,
    centerY: Double,
    activeWorkspace: omniwm_uuid? = nil,
    previousWorkspace: omniwm_uuid? = nil
) -> omniwm_workspace_navigation_monitor {
    omniwm_workspace_navigation_monitor(
        monitor_id: id,
        frame_min_x: minX,
        frame_max_y: maxY,
        center_x: centerX,
        center_y: centerY,
        active_workspace_id: activeWorkspace ?? omniwm_uuid(),
        previous_workspace_id: previousWorkspace ?? omniwm_uuid(),
        has_active_workspace_id: activeWorkspace == nil ? 0 : 1,
        has_previous_workspace_id: previousWorkspace == nil ? 0 : 1
    )
}

private func makeWorkspaceNavigationWorkspace(
    id: omniwm_uuid,
    monitorId: UInt32,
    layoutKind: UInt32 = UInt32(OMNIWM_WORKSPACE_NAV_LAYOUT_NIRI),
    numericName: Int32 = 1,
    hasMonitor: Bool = true,
    hasNumericName: Bool = true,
    isEmpty: Bool = false
) -> omniwm_workspace_navigation_workspace {
    omniwm_workspace_navigation_workspace(
        workspace_id: id,
        monitor_id: monitorId,
        layout_kind: layoutKind,
        numeric_name: numericName,
        has_monitor_id: hasMonitor ? 1 : 0,
        has_numeric_name: hasNumericName ? 1 : 0,
        is_empty: isEmpty ? 1 : 0
    )
}

private func withWorkspaceNavigationOutput<Result>(
    saveCapacity: Int = 4,
    affectedWorkspaceCapacity: Int = 4,
    affectedMonitorCapacity: Int = 4,
    _ body: (
        inout omniwm_workspace_navigation_output,
        UnsafeMutableBufferPointer<omniwm_uuid>,
        UnsafeMutableBufferPointer<omniwm_uuid>,
        UnsafeMutableBufferPointer<UInt32>
    ) -> Result
) -> Result {
    var saveWorkspaceIds = Array(repeating: omniwm_uuid(), count: saveCapacity)
    var affectedWorkspaceIds = Array(repeating: omniwm_uuid(), count: affectedWorkspaceCapacity)
    var affectedMonitorIds = Array(repeating: UInt32.zero, count: affectedMonitorCapacity)

    return saveWorkspaceIds.withUnsafeMutableBufferPointer { saveBuffer in
        affectedWorkspaceIds.withUnsafeMutableBufferPointer { affectedWorkspaceBuffer in
            affectedMonitorIds.withUnsafeMutableBufferPointer { affectedMonitorBuffer in
                var output = omniwm_workspace_navigation_output(
                    outcome: 0,
                    subject_kind: 0,
                    focus_action: 0,
                    source_workspace_id: omniwm_uuid(),
                    target_workspace_id: omniwm_uuid(),
                    source_monitor_id: 0,
                    target_monitor_id: 0,
                    subject_token: omniwm_window_token(),
                    save_workspace_ids: saveBuffer.baseAddress,
                    save_workspace_capacity: saveBuffer.count,
                    save_workspace_count: 0,
                    affected_workspace_ids: affectedWorkspaceBuffer.baseAddress,
                    affected_workspace_capacity: affectedWorkspaceBuffer.count,
                    affected_workspace_count: 0,
                    affected_monitor_ids: affectedMonitorBuffer.baseAddress,
                    affected_monitor_capacity: affectedMonitorBuffer.count,
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
                return body(
                    &output,
                    saveBuffer,
                    affectedWorkspaceBuffer,
                    affectedMonitorBuffer
                )
            }
        }
    }
}

@Suite struct WorkspaceNavigationKernelABITests {
    @Test func nullPointersReturnInvalidArgument() {
        var input = omniwm_workspace_navigation_input()
        var output = omniwm_workspace_navigation_output()

        #expect(
            omniwm_workspace_navigation_plan(nil, nil, 0, nil, 0, &output)
                == OMNIWM_KERNELS_STATUS_INVALID_ARGUMENT
        )
        #expect(
            omniwm_workspace_navigation_plan(&input, nil, 0, nil, 0, nil)
                == OMNIWM_KERNELS_STATUS_INVALID_ARGUMENT
        )
    }

    @Test func explicitSwitchPlansWorkspaceHandoffAndSaveDirective() {
        let workspaceOne = makeWorkspaceNavigationUUID(high: 1, low: 1)
        let workspaceTwo = makeWorkspaceNavigationUUID(high: 2, low: 2)
        var input = makeWorkspaceNavigationInput(
            operation: UInt32(OMNIWM_WORKSPACE_NAV_OPERATION_SWITCH_WORKSPACE_EXPLICIT),
            currentWorkspace: workspaceOne,
            targetWorkspace: workspaceTwo
        )
        let monitors = [
            makeWorkspaceNavigationMonitor(
                id: 100,
                minX: 0,
                maxY: 1080,
                centerX: 960,
                centerY: 540,
                activeWorkspace: workspaceOne
            )
        ]
        let workspaces = [
            makeWorkspaceNavigationWorkspace(id: workspaceOne, monitorId: 100, numericName: 1),
            makeWorkspaceNavigationWorkspace(id: workspaceTwo, monitorId: 100, numericName: 2, isEmpty: true)
        ]

        withWorkspaceNavigationOutput { output, saveBuffer, _, _ in
            let status = monitors.withUnsafeBufferPointer { monitorBuffer in
                workspaces.withUnsafeBufferPointer { workspaceBuffer in
                    omniwm_workspace_navigation_plan(
                        &input,
                        monitorBuffer.baseAddress,
                        monitorBuffer.count,
                        workspaceBuffer.baseAddress,
                        workspaceBuffer.count,
                        &output
                    )
                }
            }

            #expect(status == OMNIWM_KERNELS_STATUS_OK)
            #expect(output.outcome == UInt32(OMNIWM_WORKSPACE_NAV_OUTCOME_EXECUTE))
            #expect(output.focus_action == UInt32(OMNIWM_WORKSPACE_NAV_FOCUS_WORKSPACE_HANDOFF))
            #expect(output.should_hide_focus_border == 1)
            #expect(output.should_activate_target_workspace == 1)
            #expect(output.should_commit_workspace_transition == 1)
            #expect(output.save_workspace_count == 1)
            #expect(saveBuffer[0].high == workspaceOne.high)
            #expect(saveBuffer[0].low == workspaceOne.low)
            #expect(output.target_workspace_id.high == workspaceTwo.high)
            #expect(output.target_workspace_id.low == workspaceTwo.low)
            #expect(output.target_monitor_id == 100)
        }
    }

    @Test func adjacentWindowMovePlansSourceRecoveryAndAffectedSets() {
        let workspaceOne = makeWorkspaceNavigationUUID(high: 11, low: 11)
        let workspaceTwo = makeWorkspaceNavigationUUID(high: 22, low: 22)
        let token = makeWorkspaceNavigationToken(pid: 77, windowId: 9901)
        var input = makeWorkspaceNavigationInput(
            operation: UInt32(OMNIWM_WORKSPACE_NAV_OPERATION_MOVE_WINDOW_ADJACENT),
            direction: UInt32(OMNIWM_NIRI_TOPOLOGY_DIRECTION_DOWN),
            currentWorkspace: workspaceOne,
            sourceWorkspace: workspaceOne,
            currentMonitorId: 500,
            focused: token
        )
        let monitors = [
            makeWorkspaceNavigationMonitor(
                id: 500,
                minX: 0,
                maxY: 1080,
                centerX: 960,
                centerY: 540,
                activeWorkspace: workspaceOne
            )
        ]
        let workspaces = [
            makeWorkspaceNavigationWorkspace(id: workspaceOne, monitorId: 500, numericName: 1),
            makeWorkspaceNavigationWorkspace(
                id: workspaceTwo,
                monitorId: 500,
                layoutKind: UInt32(OMNIWM_WORKSPACE_NAV_LAYOUT_DWINDLE),
                numericName: 2,
                isEmpty: true
            )
        ]

        withWorkspaceNavigationOutput { output, saveBuffer, affectedWorkspaceBuffer, affectedMonitorBuffer in
            let status = monitors.withUnsafeBufferPointer { monitorBuffer in
                workspaces.withUnsafeBufferPointer { workspaceBuffer in
                    omniwm_workspace_navigation_plan(
                        &input,
                        monitorBuffer.baseAddress,
                        monitorBuffer.count,
                        workspaceBuffer.baseAddress,
                        workspaceBuffer.count,
                        &output
                    )
                }
            }

            #expect(status == OMNIWM_KERNELS_STATUS_OK)
            #expect(output.outcome == UInt32(OMNIWM_WORKSPACE_NAV_OUTCOME_EXECUTE))
            #expect(output.subject_kind == UInt32(OMNIWM_WORKSPACE_NAV_SUBJECT_WINDOW))
            #expect(output.has_subject_token == 1)
            #expect(output.subject_token.pid == token.pid)
            #expect(output.subject_token.window_id == token.window_id)
            #expect(output.focus_action == UInt32(OMNIWM_WORKSPACE_NAV_FOCUS_RECOVER_SOURCE))
            #expect(output.save_workspace_count == 1)
            #expect(output.affected_workspace_count == 2)
            #expect(output.affected_monitor_count == 1)
            #expect(saveBuffer[0].high == workspaceOne.high)
            #expect(affectedWorkspaceBuffer[0].high == workspaceTwo.high || affectedWorkspaceBuffer[1].high == workspaceTwo.high)
            #expect(affectedMonitorBuffer[0] == 500)
        }
    }

    @Test func relativeWorkspaceBoundaryStillRequestsFocusBorderHide() {
        let workspaceOne = makeWorkspaceNavigationUUID(high: 41, low: 41)
        var input = makeWorkspaceNavigationInput(
            operation: UInt32(OMNIWM_WORKSPACE_NAV_OPERATION_SWITCH_WORKSPACE_RELATIVE),
            direction: UInt32(OMNIWM_NIRI_TOPOLOGY_DIRECTION_RIGHT),
            currentWorkspace: workspaceOne,
            currentMonitorId: 900,
            wrapAround: false
        )
        let monitors = [
            makeWorkspaceNavigationMonitor(
                id: 900,
                minX: 0,
                maxY: 1080,
                centerX: 960,
                centerY: 540,
                activeWorkspace: workspaceOne
            )
        ]
        let workspaces = [
            makeWorkspaceNavigationWorkspace(id: workspaceOne, monitorId: 900, numericName: 1)
        ]

        withWorkspaceNavigationOutput { output, _, _, _ in
            let status = monitors.withUnsafeBufferPointer { monitorBuffer in
                workspaces.withUnsafeBufferPointer { workspaceBuffer in
                    omniwm_workspace_navigation_plan(
                        &input,
                        monitorBuffer.baseAddress,
                        monitorBuffer.count,
                        workspaceBuffer.baseAddress,
                        workspaceBuffer.count,
                        &output
                    )
                }
            }

            #expect(status == OMNIWM_KERNELS_STATUS_OK)
            #expect(output.outcome == UInt32(OMNIWM_WORKSPACE_NAV_OUTCOME_NOOP))
            #expect(output.should_hide_focus_border == 1)
            #expect(output.should_activate_target_workspace == 0)
        }
    }

    @Test func explicitWindowMoveDoesNotSaveSourceWorkspaceState() {
        let workspaceOne = makeWorkspaceNavigationUUID(high: 51, low: 51)
        let workspaceTwo = makeWorkspaceNavigationUUID(high: 52, low: 52)
        let token = makeWorkspaceNavigationToken(pid: 91, windowId: 5001)
        var input = makeWorkspaceNavigationInput(
            operation: UInt32(OMNIWM_WORKSPACE_NAV_OPERATION_MOVE_WINDOW_EXPLICIT),
            sourceWorkspace: workspaceOne,
            targetWorkspace: workspaceTwo,
            focused: token,
            followFocus: false
        )
        let monitors = [
            makeWorkspaceNavigationMonitor(
                id: 910,
                minX: 0,
                maxY: 1080,
                centerX: 960,
                centerY: 540,
                activeWorkspace: workspaceOne
            ),
            makeWorkspaceNavigationMonitor(
                id: 911,
                minX: 1920,
                maxY: 1080,
                centerX: 2880,
                centerY: 540,
                activeWorkspace: workspaceTwo
            )
        ]
        let workspaces = [
            makeWorkspaceNavigationWorkspace(id: workspaceOne, monitorId: 910, numericName: 1),
            makeWorkspaceNavigationWorkspace(id: workspaceTwo, monitorId: 911, numericName: 2)
        ]

        withWorkspaceNavigationOutput { output, _, affectedWorkspaceBuffer, _ in
            let status = monitors.withUnsafeBufferPointer { monitorBuffer in
                workspaces.withUnsafeBufferPointer { workspaceBuffer in
                    omniwm_workspace_navigation_plan(
                        &input,
                        monitorBuffer.baseAddress,
                        monitorBuffer.count,
                        workspaceBuffer.baseAddress,
                        workspaceBuffer.count,
                        &output
                    )
                }
            }

            #expect(status == OMNIWM_KERNELS_STATUS_OK)
            #expect(output.outcome == UInt32(OMNIWM_WORKSPACE_NAV_OUTCOME_EXECUTE))
            #expect(output.save_workspace_count == 0)
            #expect(output.affected_workspace_count == 2)
            #expect(
                affectedWorkspaceBuffer[0].high == workspaceOne.high
                    || affectedWorkspaceBuffer[1].high == workspaceOne.high
            )
        }
    }

    @Test func swapPlansClosestDirectionalMonitorWorkspace() {
        let workspaceCenter = makeWorkspaceNavigationUUID(high: 61, low: 61)
        let workspaceNear = makeWorkspaceNavigationUUID(high: 62, low: 62)
        let workspaceFar = makeWorkspaceNavigationUUID(high: 63, low: 63)
        var input = makeWorkspaceNavigationInput(
            operation: UInt32(OMNIWM_WORKSPACE_NAV_OPERATION_SWAP_WORKSPACE_WITH_MONITOR),
            direction: UInt32(OMNIWM_NIRI_TOPOLOGY_DIRECTION_RIGHT),
            currentWorkspace: workspaceCenter,
            currentMonitorId: 920
        )
        let monitors = [
            makeWorkspaceNavigationMonitor(
                id: 920,
                minX: 0,
                maxY: 1080,
                centerX: 960,
                centerY: 540,
                activeWorkspace: workspaceCenter
            ),
            makeWorkspaceNavigationMonitor(
                id: 921,
                minX: 1100,
                maxY: 1430,
                centerX: 2060,
                centerY: 890,
                activeWorkspace: workspaceNear
            ),
            makeWorkspaceNavigationMonitor(
                id: 922,
                minX: 1800,
                maxY: 1080,
                centerX: 2760,
                centerY: 540,
                activeWorkspace: workspaceFar
            )
        ]
        let workspaces = [
            makeWorkspaceNavigationWorkspace(id: workspaceCenter, monitorId: 920, numericName: 1),
            makeWorkspaceNavigationWorkspace(id: workspaceNear, monitorId: 921, numericName: 2),
            makeWorkspaceNavigationWorkspace(id: workspaceFar, monitorId: 922, numericName: 3)
        ]

        withWorkspaceNavigationOutput { output, _, affectedWorkspaceBuffer, affectedMonitorBuffer in
            let status = monitors.withUnsafeBufferPointer { monitorBuffer in
                workspaces.withUnsafeBufferPointer { workspaceBuffer in
                    omniwm_workspace_navigation_plan(
                        &input,
                        monitorBuffer.baseAddress,
                        monitorBuffer.count,
                        workspaceBuffer.baseAddress,
                        workspaceBuffer.count,
                        &output
                    )
                }
            }

            #expect(status == OMNIWM_KERNELS_STATUS_OK)
            #expect(output.outcome == UInt32(OMNIWM_WORKSPACE_NAV_OUTCOME_EXECUTE))
            #expect(output.target_monitor_id == 921)
            #expect(output.target_workspace_id.high == workspaceNear.high)
            #expect(output.affected_workspace_count == 2)
            #expect(output.affected_monitor_count == 2)
            #expect(
                affectedWorkspaceBuffer[0].high == workspaceNear.high
                    || affectedWorkspaceBuffer[1].high == workspaceNear.high
            )
            #expect(Set(affectedMonitorBuffer.prefix(2)) == Set([920, 921]))
        }
    }

    @Test func callerAllocatedOutputBuffersReportWhenTooSmall() {
        let workspaceOne = makeWorkspaceNavigationUUID(high: 31, low: 31)
        let workspaceTwo = makeWorkspaceNavigationUUID(high: 32, low: 32)
        let token = makeWorkspaceNavigationToken(pid: 88, windowId: 4401)
        var input = makeWorkspaceNavigationInput(
            operation: UInt32(OMNIWM_WORKSPACE_NAV_OPERATION_MOVE_WINDOW_EXPLICIT),
            sourceWorkspace: workspaceOne,
            targetWorkspace: workspaceTwo,
            focused: token
        )
        let monitors = [
            makeWorkspaceNavigationMonitor(
                id: 700,
                minX: 0,
                maxY: 1080,
                centerX: 960,
                centerY: 540,
                activeWorkspace: workspaceOne
            ),
            makeWorkspaceNavigationMonitor(
                id: 701,
                minX: 1920,
                maxY: 1080,
                centerX: 2880,
                centerY: 540,
                activeWorkspace: workspaceTwo
            )
        ]
        let workspaces = [
            makeWorkspaceNavigationWorkspace(id: workspaceOne, monitorId: 700, numericName: 1),
            makeWorkspaceNavigationWorkspace(id: workspaceTwo, monitorId: 701, numericName: 2)
        ]

        withWorkspaceNavigationOutput(saveCapacity: 1, affectedWorkspaceCapacity: 1, affectedMonitorCapacity: 1) {
            output,
            _,
            _,
            _
            in
            let status = monitors.withUnsafeBufferPointer { monitorBuffer in
                workspaces.withUnsafeBufferPointer { workspaceBuffer in
                    omniwm_workspace_navigation_plan(
                        &input,
                        monitorBuffer.baseAddress,
                        monitorBuffer.count,
                        workspaceBuffer.baseAddress,
                        workspaceBuffer.count,
                        &output
                    )
                }
            }

            #expect(status == OMNIWM_KERNELS_STATUS_BUFFER_TOO_SMALL)
            #expect(output.save_workspace_count == 0)
            #expect(output.affected_workspace_count == 2)
            #expect(output.affected_monitor_count == 2)
        }
    }
}
