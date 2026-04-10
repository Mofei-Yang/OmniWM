const std = @import("std");

const status_ok: i32 = 0;
const status_invalid_argument: i32 = 1;
const status_buffer_too_small: i32 = 3;

const op_focus_monitor_cyclic: u32 = 0;
const op_focus_monitor_last: u32 = 1;
const op_swap_workspace_with_monitor: u32 = 2;
const op_switch_workspace_explicit: u32 = 3;
const op_switch_workspace_relative: u32 = 4;
const op_focus_workspace_anywhere: u32 = 5;
const op_workspace_back_and_forth: u32 = 6;
const op_move_window_adjacent: u32 = 7;
const op_move_window_explicit: u32 = 8;
const op_move_column_adjacent: u32 = 9;
const op_move_column_explicit: u32 = 10;
const op_move_window_to_workspace_on_monitor: u32 = 11;
const op_move_window_handle: u32 = 12;

const outcome_noop: u32 = 0;
const outcome_execute: u32 = 1;
const outcome_invalid_target: u32 = 2;
const outcome_blocked: u32 = 3;

const layout_default: u32 = 0;
const layout_niri: u32 = 1;
const layout_dwindle: u32 = 2;

const subject_none: u32 = 0;
const subject_window: u32 = 1;
const subject_column: u32 = 2;

const focus_none: u32 = 0;
const focus_workspace_handoff: u32 = 1;
const focus_resolve_target_if_present: u32 = 2;
const focus_subject: u32 = 3;
const focus_recover_source: u32 = 4;

const direction_left: u32 = 0;
const direction_right: u32 = 1;
const direction_up: u32 = 2;
const direction_down: u32 = 3;

const UUID = extern struct {
    high: u64,
    low: u64,
};

const WindowToken = extern struct {
    pid: i32,
    window_id: i64,
};

const Input = extern struct {
    operation: u32,
    direction: u32,
    current_workspace_id: UUID,
    source_workspace_id: UUID,
    target_workspace_id: UUID,
    current_monitor_id: u32,
    previous_monitor_id: u32,
    subject_token: WindowToken,
    focused_token: WindowToken,
    selected_token: WindowToken,
    has_current_workspace_id: u8,
    has_source_workspace_id: u8,
    has_target_workspace_id: u8,
    has_current_monitor_id: u8,
    has_previous_monitor_id: u8,
    has_subject_token: u8,
    has_focused_token: u8,
    has_selected_token: u8,
    wrap_around: u8,
    follow_focus: u8,
};

const MonitorSnapshot = extern struct {
    monitor_id: u32,
    frame_min_x: f64,
    frame_max_y: f64,
    center_x: f64,
    center_y: f64,
    active_workspace_id: UUID,
    previous_workspace_id: UUID,
    has_active_workspace_id: u8,
    has_previous_workspace_id: u8,
};

const WorkspaceSnapshot = extern struct {
    workspace_id: UUID,
    monitor_id: u32,
    layout_kind: u32,
    numeric_name: i32,
    has_monitor_id: u8,
    has_numeric_name: u8,
    is_empty: u8,
};

const Output = extern struct {
    outcome: u32,
    subject_kind: u32,
    focus_action: u32,
    source_workspace_id: UUID,
    target_workspace_id: UUID,
    source_monitor_id: u32,
    target_monitor_id: u32,
    subject_token: WindowToken,
    save_workspace_ids: [*]UUID,
    save_workspace_capacity: usize,
    save_workspace_count: usize,
    affected_workspace_ids: [*]UUID,
    affected_workspace_capacity: usize,
    affected_workspace_count: usize,
    affected_monitor_ids: [*]u32,
    affected_monitor_capacity: usize,
    affected_monitor_count: usize,
    has_source_workspace_id: u8,
    has_target_workspace_id: u8,
    has_source_monitor_id: u8,
    has_target_monitor_id: u8,
    has_subject_token: u8,
    should_activate_target_workspace: u8,
    should_set_interaction_monitor: u8,
    should_sync_monitors_to_niri: u8,
    should_hide_focus_border: u8,
    should_commit_workspace_transition: u8,
};

const MonitorSelectionMode = enum {
    directional,
    wrapped,
};

const MonitorSelectionRank = struct {
    primary: f64,
    secondary: f64,
    distance: ?f64,
};

fn zeroUUID() UUID {
    return .{ .high = 0, .low = 0 };
}

fn zeroToken() WindowToken {
    return .{ .pid = 0, .window_id = 0 };
}

fn uuidEq(lhs: UUID, rhs: UUID) bool {
    return lhs.high == rhs.high and lhs.low == rhs.low;
}

fn tokenEq(lhs: WindowToken, rhs: WindowToken) bool {
    return lhs.pid == rhs.pid and lhs.window_id == rhs.window_id;
}

fn directionOffset(direction: u32) i32 {
    return switch (direction) {
        direction_right, direction_down => 1,
        direction_left, direction_up => -1,
        else => 0,
    };
}

fn movementOffset(direction: u32) i32 {
    return if (direction == direction_down) 1 else -1;
}

fn resetOutput(output: *Output) void {
    const save_workspace_ids = output.save_workspace_ids;
    const save_workspace_capacity = output.save_workspace_capacity;
    const affected_workspace_ids = output.affected_workspace_ids;
    const affected_workspace_capacity = output.affected_workspace_capacity;
    const affected_monitor_ids = output.affected_monitor_ids;
    const affected_monitor_capacity = output.affected_monitor_capacity;
    output.* = std.mem.zeroes(Output);
    output.save_workspace_ids = save_workspace_ids;
    output.save_workspace_capacity = save_workspace_capacity;
    output.affected_workspace_ids = affected_workspace_ids;
    output.affected_workspace_capacity = affected_workspace_capacity;
    output.affected_monitor_ids = affected_monitor_ids;
    output.affected_monitor_capacity = affected_monitor_capacity;
    output.outcome = outcome_noop;
    output.subject_kind = subject_none;
    output.focus_action = focus_none;
    output.source_workspace_id = zeroUUID();
    output.target_workspace_id = zeroUUID();
    output.subject_token = zeroToken();
}

fn appendUUID(
    buffer: [*]UUID,
    capacity: usize,
    count: *usize,
    value: UUID,
) i32 {
    if (uuidEq(value, zeroUUID())) return status_ok;

    var index: usize = 0;
    while (index < count.*) : (index += 1) {
        if (uuidEq(buffer[index], value)) {
            return status_ok;
        }
    }

    if (count.* >= capacity) {
        count.* += 1;
        return status_buffer_too_small;
    }

    buffer[count.*] = value;
    count.* += 1;
    return status_ok;
}

fn appendMonitorId(
    buffer: [*]u32,
    capacity: usize,
    count: *usize,
    value: u32,
) i32 {
    if (value == 0) return status_ok;

    var index: usize = 0;
    while (index < count.*) : (index += 1) {
        if (buffer[index] == value) {
            return status_ok;
        }
    }

    if (count.* >= capacity) {
        count.* += 1;
        return status_buffer_too_small;
    }

    buffer[count.*] = value;
    count.* += 1;
    return status_ok;
}

fn saveWorkspace(output: *Output, workspace_id: UUID) i32 {
    return appendUUID(
        output.save_workspace_ids,
        output.save_workspace_capacity,
        &output.save_workspace_count,
        workspace_id,
    );
}

fn affectWorkspace(output: *Output, workspace_id: UUID) i32 {
    return appendUUID(
        output.affected_workspace_ids,
        output.affected_workspace_capacity,
        &output.affected_workspace_count,
        workspace_id,
    );
}

fn affectMonitor(output: *Output, monitor_id: u32) i32 {
    return appendMonitorId(
        output.affected_monitor_ids,
        output.affected_monitor_capacity,
        &output.affected_monitor_count,
        monitor_id,
    );
}

fn setSubject(output: *Output, kind: u32, token: WindowToken) void {
    output.subject_kind = kind;
    output.subject_token = token;
    output.has_subject_token = if (kind == subject_none) 0 else 1;
}

fn setSourceWorkspace(output: *Output, workspace: *const WorkspaceSnapshot) void {
    output.source_workspace_id = workspace.workspace_id;
    output.has_source_workspace_id = 1;
    if (workspace.has_monitor_id != 0) {
        output.source_monitor_id = workspace.monitor_id;
        output.has_source_monitor_id = 1;
    }
}

fn setTargetWorkspace(output: *Output, workspace: *const WorkspaceSnapshot) void {
    output.target_workspace_id = workspace.workspace_id;
    output.has_target_workspace_id = 1;
    if (workspace.has_monitor_id != 0) {
        output.target_monitor_id = workspace.monitor_id;
        output.has_target_monitor_id = 1;
    }
}

fn monitorSortLess(
    monitors: []const MonitorSnapshot,
    lhs_index: usize,
    rhs_index: usize,
) bool {
    const lhs = monitors[lhs_index];
    const rhs = monitors[rhs_index];
    if (lhs.frame_min_x != rhs.frame_min_x) {
        return lhs.frame_min_x < rhs.frame_min_x;
    }
    if (lhs.frame_max_y != rhs.frame_max_y) {
        return lhs.frame_max_y > rhs.frame_max_y;
    }
    return lhs_index < rhs_index;
}

fn monitorSortKeyLess(lhs: MonitorSnapshot, rhs: MonitorSnapshot) bool {
    if (lhs.frame_min_x != rhs.frame_min_x) {
        return lhs.frame_min_x < rhs.frame_min_x;
    }
    if (lhs.frame_max_y != rhs.frame_max_y) {
        return lhs.frame_max_y > rhs.frame_max_y;
    }
    return lhs.monitor_id < rhs.monitor_id;
}

fn findMonitorIndexById(monitors: []const MonitorSnapshot, monitor_id: u32) ?usize {
    for (monitors, 0..) |monitor, index| {
        if (monitor.monitor_id == monitor_id) {
            return index;
        }
    }
    return null;
}

fn findWorkspaceIndexById(workspaces: []const WorkspaceSnapshot, workspace_id: UUID) ?usize {
    for (workspaces, 0..) |workspace, index| {
        if (uuidEq(workspace.workspace_id, workspace_id)) {
            return index;
        }
    }
    return null;
}

fn firstWorkspaceOnMonitor(workspaces: []const WorkspaceSnapshot, monitor_id: u32) ?usize {
    for (workspaces, 0..) |workspace, index| {
        if (workspace.has_monitor_id != 0 and workspace.monitor_id == monitor_id) {
            return index;
        }
    }
    return null;
}

fn workspaceIndexOnMonitor(
    workspaces: []const WorkspaceSnapshot,
    monitor_id: u32,
    workspace_id: UUID,
) ?usize {
    var filtered_index: usize = 0;
    for (workspaces) |workspace| {
        if (workspace.has_monitor_id == 0 or workspace.monitor_id != monitor_id) continue;
        if (uuidEq(workspace.workspace_id, workspace_id)) {
            return filtered_index;
        }
        filtered_index += 1;
    }
    return null;
}

fn workspaceAtMonitorIndex(
    workspaces: []const WorkspaceSnapshot,
    monitor_id: u32,
    desired_index: usize,
) ?usize {
    var filtered_index: usize = 0;
    for (workspaces, 0..) |workspace, index| {
        if (workspace.has_monitor_id == 0 or workspace.monitor_id != monitor_id) continue;
        if (filtered_index == desired_index) {
            return index;
        }
        filtered_index += 1;
    }
    return null;
}

fn workspaceCountOnMonitor(workspaces: []const WorkspaceSnapshot, monitor_id: u32) usize {
    var count: usize = 0;
    for (workspaces) |workspace| {
        if (workspace.has_monitor_id != 0 and workspace.monitor_id == monitor_id) {
            count += 1;
        }
    }
    return count;
}

fn activeOrFirstWorkspaceOnMonitor(
    monitors: []const MonitorSnapshot,
    workspaces: []const WorkspaceSnapshot,
    monitor_id: u32,
) ?usize {
    if (findMonitorIndexById(monitors, monitor_id)) |monitor_index| {
        const monitor = monitors[monitor_index];
        if (monitor.has_active_workspace_id != 0) {
            if (findWorkspaceIndexById(workspaces, monitor.active_workspace_id)) |workspace_index| {
                return workspace_index;
            }
        }
    }
    return firstWorkspaceOnMonitor(workspaces, monitor_id);
}

fn relativeWorkspaceOnMonitor(
    workspaces: []const WorkspaceSnapshot,
    monitor_id: u32,
    current_workspace_id: UUID,
    offset: i32,
    wrap_around: bool,
) ?usize {
    const count = workspaceCountOnMonitor(workspaces, monitor_id);
    if (count <= 1) return null;

    const current_index = workspaceIndexOnMonitor(workspaces, monitor_id, current_workspace_id) orelse return null;
    const desired = @as(i32, @intCast(current_index)) + offset;
    if (wrap_around) {
        const wrapped = @mod(desired, @as(i32, @intCast(count)));
        return workspaceAtMonitorIndex(workspaces, monitor_id, @intCast(wrapped));
    }
    if (desired < 0 or desired >= @as(i32, @intCast(count))) {
        return null;
    }
    return workspaceAtMonitorIndex(workspaces, monitor_id, @intCast(desired));
}

fn monitorSelectionRank(
    candidate: MonitorSnapshot,
    current: MonitorSnapshot,
    direction: u32,
    mode: MonitorSelectionMode,
) MonitorSelectionRank {
    const dx = candidate.center_x - current.center_x;
    const dy = candidate.center_y - current.center_y;

    return switch (mode) {
        .directional => switch (direction) {
            direction_left, direction_right => .{
                .primary = @abs(dx),
                .secondary = @abs(dy),
                .distance = dx * dx + dy * dy,
            },
            direction_up, direction_down => .{
                .primary = @abs(dy),
                .secondary = @abs(dx),
                .distance = dx * dx + dy * dy,
            },
            else => .{ .primary = 0, .secondary = 0, .distance = 0 },
        },
        .wrapped => switch (direction) {
            direction_right => .{ .primary = candidate.center_x, .secondary = @abs(dy), .distance = null },
            direction_left => .{ .primary = -candidate.center_x, .secondary = @abs(dy), .distance = null },
            direction_up => .{ .primary = candidate.center_y, .secondary = @abs(dx), .distance = null },
            direction_down => .{ .primary = -candidate.center_y, .secondary = @abs(dx), .distance = null },
            else => .{ .primary = 0, .secondary = 0, .distance = null },
        },
    };
}

fn betterMonitorCandidate(
    lhs: MonitorSnapshot,
    rhs: MonitorSnapshot,
    current: MonitorSnapshot,
    direction: u32,
    mode: MonitorSelectionMode,
) bool {
    const lhs_rank = monitorSelectionRank(lhs, current, direction, mode);
    const rhs_rank = monitorSelectionRank(rhs, current, direction, mode);

    if (lhs_rank.primary != rhs_rank.primary) {
        return lhs_rank.primary < rhs_rank.primary;
    }
    if (lhs_rank.secondary != rhs_rank.secondary) {
        return lhs_rank.secondary < rhs_rank.secondary;
    }
    if (lhs_rank.distance != null and rhs_rank.distance != null and lhs_rank.distance.? != rhs_rank.distance.?) {
        return lhs_rank.distance.? < rhs_rank.distance.?;
    }
    return monitorSortKeyLess(lhs, rhs);
}

fn adjacentMonitorIndex(
    monitors: []const MonitorSnapshot,
    current_monitor_id: u32,
    direction: u32,
    wrap_around: bool,
) ?usize {
    const current_index = findMonitorIndexById(monitors, current_monitor_id) orelse return null;
    const current = monitors[current_index];

    var best_directional: ?usize = null;
    var best_wrapped: ?usize = null;

    for (monitors, 0..) |candidate, candidate_index| {
        if (candidate.monitor_id == current.monitor_id) continue;

        const dx = candidate.center_x - current.center_x;
        const dy = candidate.center_y - current.center_y;
        const is_directional = switch (direction) {
            direction_left => dx < 0,
            direction_right => dx > 0,
            direction_up => dy > 0,
            direction_down => dy < 0,
            else => false,
        };

        if (is_directional) {
            if (best_directional == null or betterMonitorCandidate(
                candidate,
                monitors[best_directional.?],
                current,
                direction,
                .directional,
            )) {
                best_directional = candidate_index;
            }
        }

        if (wrap_around) {
            if (best_wrapped == null or betterMonitorCandidate(
                candidate,
                monitors[best_wrapped.?],
                current,
                direction,
                .wrapped,
            )) {
                best_wrapped = candidate_index;
            }
        }
    }

    return best_directional orelse best_wrapped;
}

fn cyclicMonitorIndex(monitors: []const MonitorSnapshot, current_monitor_id: u32, previous: bool) ?usize {
    if (monitors.len <= 1) return null;
    const current_index = findMonitorIndexById(monitors, current_monitor_id) orelse return null;

    var rank: usize = 0;
    for (monitors, 0..) |_, index| {
        if (index != current_index and monitorSortLess(monitors, index, current_index)) {
            rank += 1;
        }
    }

    const desired_rank = if (previous)
        if (rank > 0) rank - 1 else monitors.len - 1
    else
        (rank + 1) % monitors.len;

    for (monitors, 0..) |_, index| {
        var candidate_rank: usize = 0;
        for (monitors, 0..) |_, other_index| {
            if (other_index != index and monitorSortLess(monitors, other_index, index)) {
                candidate_rank += 1;
            }
        }
        if (candidate_rank == desired_rank) {
            return index;
        }
    }

    return null;
}

fn sourceWorkspaceIndex(input: Input, workspaces: []const WorkspaceSnapshot) ?usize {
    if (input.has_source_workspace_id == 0) return null;
    return findWorkspaceIndexById(workspaces, input.source_workspace_id);
}

fn explicitTargetWorkspaceIndex(input: Input, workspaces: []const WorkspaceSnapshot) ?usize {
    if (input.has_target_workspace_id == 0) return null;
    return findWorkspaceIndexById(workspaces, input.target_workspace_id);
}

fn commitTransferPlan(
    output: *Output,
    source_workspace: ?*const WorkspaceSnapshot,
    target_workspace: *const WorkspaceSnapshot,
    subject_kind: u32,
    subject_token: WindowToken,
    follow_focus: bool,
    commit_transition: bool,
    save_source_workspace: bool,
) i32 {
    var status = status_ok;
    output.outcome = outcome_execute;
    output.focus_action = if (follow_focus) focus_subject else focus_recover_source;
    output.should_commit_workspace_transition = @intFromBool(commit_transition);
    output.should_activate_target_workspace = @intFromBool(follow_focus);
    output.should_set_interaction_monitor = @intFromBool(follow_focus);
    setSubject(output, subject_kind, subject_token);
    setTargetWorkspace(output, target_workspace);
    status = affectWorkspace(output, target_workspace.workspace_id);
    if (output.has_target_monitor_id != 0) {
        const next_status = affectMonitor(output, output.target_monitor_id);
        if (status == status_ok) status = next_status;
    }

    if (source_workspace) |source| {
        setSourceWorkspace(output, source);
        if (save_source_workspace) {
            const next_save = saveWorkspace(output, source.workspace_id);
            if (status == status_ok) status = next_save;
        }
        const next_affect = affectWorkspace(output, source.workspace_id);
        if (status == status_ok) status = next_affect;
        if (output.has_source_monitor_id != 0) {
            const next_monitor = affectMonitor(output, output.source_monitor_id);
            if (status == status_ok) status = next_monitor;
        }
    }

    return status;
}

fn plan(input: Input, monitors: []const MonitorSnapshot, workspaces: []const WorkspaceSnapshot, output: *Output) i32 {
    switch (input.operation) {
        op_switch_workspace_explicit => {
            output.should_hide_focus_border = 1;
            const target_index = explicitTargetWorkspaceIndex(input, workspaces) orelse {
                output.outcome = outcome_invalid_target;
                return status_ok;
            };
            const target = &workspaces[target_index];
            if (target.has_monitor_id == 0 or findMonitorIndexById(monitors, target.monitor_id) == null) {
                output.outcome = outcome_invalid_target;
                return status_ok;
            }
            if (input.has_current_workspace_id != 0 and uuidEq(input.current_workspace_id, target.workspace_id)) {
                output.outcome = outcome_noop;
                return status_ok;
            }

            output.outcome = outcome_execute;
            output.focus_action = focus_workspace_handoff;
            output.should_activate_target_workspace = 1;
            output.should_set_interaction_monitor = 1;
            output.should_commit_workspace_transition = 1;
            setTargetWorkspace(output, target);
            if (input.has_current_workspace_id != 0) {
                return saveWorkspace(output, input.current_workspace_id);
            }
            return status_ok;
        },
        op_switch_workspace_relative => {
            output.should_hide_focus_border = 1;
            if (input.has_current_monitor_id == 0 or input.has_current_workspace_id == 0) {
                output.outcome = outcome_blocked;
                return status_ok;
            }
            const target_index = relativeWorkspaceOnMonitor(
                workspaces,
                input.current_monitor_id,
                input.current_workspace_id,
                directionOffset(input.direction),
                input.wrap_around != 0,
            ) orelse {
                output.outcome = outcome_noop;
                return status_ok;
            };
            const target = &workspaces[target_index];
            output.outcome = outcome_execute;
            output.focus_action = focus_workspace_handoff;
            output.should_activate_target_workspace = 1;
            output.should_set_interaction_monitor = 1;
            output.should_commit_workspace_transition = 1;
            setTargetWorkspace(output, target);
            return saveWorkspace(output, input.current_workspace_id);
        },
        op_focus_workspace_anywhere => {
            output.should_hide_focus_border = 1;
            const target_index = explicitTargetWorkspaceIndex(input, workspaces) orelse {
                output.outcome = outcome_invalid_target;
                return status_ok;
            };
            const target = &workspaces[target_index];
            if (target.has_monitor_id == 0 or findMonitorIndexById(monitors, target.monitor_id) == null) {
                output.outcome = outcome_invalid_target;
                return status_ok;
            }

            output.outcome = outcome_execute;
            output.focus_action = focus_workspace_handoff;
            output.should_activate_target_workspace = 1;
            output.should_set_interaction_monitor = 1;
            output.should_sync_monitors_to_niri = 1;
            output.should_commit_workspace_transition = 1;
            setTargetWorkspace(output, target);

            var status = status_ok;
            if (input.has_current_workspace_id != 0) {
                status = saveWorkspace(output, input.current_workspace_id);
            }
            if (input.has_current_monitor_id != 0 and input.current_monitor_id != target.monitor_id) {
                if (activeOrFirstWorkspaceOnMonitor(monitors, workspaces, target.monitor_id)) |visible_target_index| {
                    const visible_target_workspace = workspaces[visible_target_index];
                    const next_status = saveWorkspace(output, visible_target_workspace.workspace_id);
                    if (status == status_ok) status = next_status;
                }
            }
            return status;
        },
        op_workspace_back_and_forth => {
            output.should_hide_focus_border = 1;
            if (input.has_current_monitor_id == 0) {
                output.outcome = outcome_blocked;
                return status_ok;
            }
            const current_monitor_index = findMonitorIndexById(monitors, input.current_monitor_id) orelse {
                output.outcome = outcome_blocked;
                return status_ok;
            };
            const current_monitor = monitors[current_monitor_index];
            if (current_monitor.has_previous_workspace_id == 0) {
                output.outcome = outcome_noop;
                return status_ok;
            }
            if (current_monitor.has_active_workspace_id != 0 and uuidEq(
                current_monitor.previous_workspace_id,
                current_monitor.active_workspace_id,
            )) {
                output.outcome = outcome_noop;
                return status_ok;
            }
            const target_index = findWorkspaceIndexById(workspaces, current_monitor.previous_workspace_id) orelse {
                output.outcome = outcome_noop;
                return status_ok;
            };
            const target = &workspaces[target_index];
            output.outcome = outcome_execute;
            output.focus_action = focus_workspace_handoff;
            output.should_activate_target_workspace = 1;
            output.should_set_interaction_monitor = 1;
            output.should_commit_workspace_transition = 1;
            setTargetWorkspace(output, target);
            if (input.has_current_workspace_id != 0) {
                return saveWorkspace(output, input.current_workspace_id);
            }
            return status_ok;
        },
        op_focus_monitor_cyclic => {
            if (input.has_current_monitor_id == 0) {
                output.outcome = outcome_blocked;
                return status_ok;
            }
            const target_monitor_index = cyclicMonitorIndex(
                monitors,
                input.current_monitor_id,
                input.direction == direction_left or input.direction == direction_up,
            ) orelse {
                output.outcome = outcome_noop;
                return status_ok;
            };
            const target_monitor = monitors[target_monitor_index];
            const target_workspace_index = activeOrFirstWorkspaceOnMonitor(
                monitors,
                workspaces,
                target_monitor.monitor_id,
            ) orelse {
                output.outcome = outcome_noop;
                return status_ok;
            };
            const target_workspace = &workspaces[target_workspace_index];

            output.outcome = outcome_execute;
            output.focus_action = focus_resolve_target_if_present;
            output.should_activate_target_workspace = 1;
            output.should_set_interaction_monitor = 1;
            output.should_commit_workspace_transition = 1;
            setTargetWorkspace(output, target_workspace);
            var status = affectWorkspace(output, target_workspace.workspace_id);
            const next_status = affectMonitor(output, target_monitor.monitor_id);
            if (status == status_ok) status = next_status;
            return status;
        },
        op_focus_monitor_last => {
            if (input.has_current_monitor_id == 0 or input.has_previous_monitor_id == 0) {
                output.outcome = outcome_blocked;
                return status_ok;
            }
            if (input.current_monitor_id == input.previous_monitor_id) {
                output.outcome = outcome_noop;
                return status_ok;
            }
            if (findMonitorIndexById(monitors, input.previous_monitor_id) == null) {
                output.outcome = outcome_noop;
                return status_ok;
            }
            const target_workspace_index = activeOrFirstWorkspaceOnMonitor(
                monitors,
                workspaces,
                input.previous_monitor_id,
            ) orelse {
                output.outcome = outcome_noop;
                return status_ok;
            };
            const target_workspace = &workspaces[target_workspace_index];

            output.outcome = outcome_execute;
            output.focus_action = focus_resolve_target_if_present;
            output.should_activate_target_workspace = 1;
            output.should_set_interaction_monitor = 1;
            output.should_commit_workspace_transition = 1;
            setTargetWorkspace(output, target_workspace);
            var status = affectWorkspace(output, target_workspace.workspace_id);
            const next_status = affectMonitor(output, input.previous_monitor_id);
            if (status == status_ok) status = next_status;
            return status;
        },
        op_swap_workspace_with_monitor => {
            if (input.has_current_monitor_id == 0 or input.has_current_workspace_id == 0) {
                output.outcome = outcome_blocked;
                return status_ok;
            }
            const source_index = findWorkspaceIndexById(workspaces, input.current_workspace_id) orelse {
                output.outcome = outcome_blocked;
                return status_ok;
            };
            const source = &workspaces[source_index];
            const target_monitor_index = adjacentMonitorIndex(
                monitors,
                input.current_monitor_id,
                input.direction,
                false,
            ) orelse {
                output.outcome = outcome_noop;
                return status_ok;
            };
            const target_monitor = monitors[target_monitor_index];
            const target_workspace_index = activeOrFirstWorkspaceOnMonitor(
                monitors,
                workspaces,
                target_monitor.monitor_id,
            ) orelse {
                output.outcome = outcome_noop;
                return status_ok;
            };
            const target = &workspaces[target_workspace_index];

            output.outcome = outcome_execute;
            output.focus_action = focus_resolve_target_if_present;
            output.should_sync_monitors_to_niri = 1;
            output.should_commit_workspace_transition = 1;
            setSourceWorkspace(output, source);
            setTargetWorkspace(output, target);

            var status = saveWorkspace(output, source.workspace_id);
            const next_source_workspace = affectWorkspace(output, source.workspace_id);
            if (status == status_ok) status = next_source_workspace;
            const next_target_workspace = affectWorkspace(output, target.workspace_id);
            if (status == status_ok) status = next_target_workspace;
            const next_source_monitor = affectMonitor(output, input.current_monitor_id);
            if (status == status_ok) status = next_source_monitor;
            const next_target_monitor = affectMonitor(output, target_monitor.monitor_id);
            if (status == status_ok) status = next_target_monitor;
            return status;
        },
        op_move_window_adjacent => {
            const source_index = sourceWorkspaceIndex(input, workspaces) orelse {
                output.outcome = outcome_blocked;
                return status_ok;
            };
            if (input.has_focused_token == 0) {
                output.outcome = outcome_blocked;
                return status_ok;
            }
            if (input.has_current_monitor_id == 0) {
                output.outcome = outcome_blocked;
                return status_ok;
            }
            const target_index = relativeWorkspaceOnMonitor(
                workspaces,
                input.current_monitor_id,
                workspaces[source_index].workspace_id,
                movementOffset(input.direction),
                false,
            ) orelse {
                output.outcome = outcome_noop;
                return status_ok;
            };
            return commitTransferPlan(
                output,
                &workspaces[source_index],
                &workspaces[target_index],
                subject_window,
                input.focused_token,
                false,
                true,
                true,
            );
        },
        op_move_column_adjacent => {
            const source_index = sourceWorkspaceIndex(input, workspaces) orelse {
                output.outcome = outcome_blocked;
                return status_ok;
            };
            const source = &workspaces[source_index];
            if (source.layout_kind != layout_niri or input.has_focused_token == 0) {
                output.outcome = outcome_blocked;
                return status_ok;
            }
            if (input.has_current_monitor_id == 0) {
                output.outcome = outcome_blocked;
                return status_ok;
            }
            const target_index = relativeWorkspaceOnMonitor(
                workspaces,
                input.current_monitor_id,
                source.workspace_id,
                movementOffset(input.direction),
                false,
            ) orelse {
                output.outcome = outcome_noop;
                return status_ok;
            };
            return commitTransferPlan(
                output,
                source,
                &workspaces[target_index],
                subject_column,
                input.focused_token,
                false,
                true,
                true,
            );
        },
        op_move_column_explicit => {
            const source_index = sourceWorkspaceIndex(input, workspaces) orelse {
                output.outcome = outcome_blocked;
                return status_ok;
            };
            const source = &workspaces[source_index];
            if (source.layout_kind != layout_niri or input.has_selected_token == 0) {
                output.outcome = outcome_blocked;
                return status_ok;
            }
            const target_index = explicitTargetWorkspaceIndex(input, workspaces) orelse {
                output.outcome = outcome_invalid_target;
                return status_ok;
            };
            const target = &workspaces[target_index];
            if (uuidEq(source.workspace_id, target.workspace_id)) {
                output.outcome = outcome_noop;
                return status_ok;
            }
            return commitTransferPlan(
                output,
                source,
                target,
                subject_column,
                input.selected_token,
                false,
                true,
                true,
            );
        },
        op_move_window_explicit, op_move_window_handle => {
            const target_index = explicitTargetWorkspaceIndex(input, workspaces) orelse {
                output.outcome = outcome_invalid_target;
                return status_ok;
            };
            const target = &workspaces[target_index];
            const source_index = sourceWorkspaceIndex(input, workspaces);
            const subject_token = if (input.has_subject_token != 0) input.subject_token else if (input.has_focused_token != 0) input.focused_token else zeroToken();
            if (tokenEq(subject_token, zeroToken())) {
                output.outcome = outcome_blocked;
                return status_ok;
            }
            if (source_index) |index| {
                if (uuidEq(workspaces[index].workspace_id, target.workspace_id)) {
                    output.outcome = outcome_noop;
                    return status_ok;
                }
            }
            return commitTransferPlan(
                output,
                if (source_index) |index| &workspaces[index] else null,
                target,
                subject_window,
                subject_token,
                input.follow_focus != 0,
                input.operation != op_move_window_handle,
                false,
            );
        },
        op_move_window_to_workspace_on_monitor => {
            const source_index = sourceWorkspaceIndex(input, workspaces) orelse {
                output.outcome = outcome_blocked;
                return status_ok;
            };
            if (input.has_current_monitor_id == 0 or input.has_focused_token == 0) {
                output.outcome = outcome_blocked;
                return status_ok;
            }
            const target_monitor_index = adjacentMonitorIndex(
                monitors,
                input.current_monitor_id,
                input.direction,
                false,
            ) orelse {
                output.outcome = outcome_noop;
                return status_ok;
            };
            const target_monitor = monitors[target_monitor_index];
            const target_index = explicitTargetWorkspaceIndex(input, workspaces) orelse {
                output.outcome = outcome_invalid_target;
                return status_ok;
            };
            const target = &workspaces[target_index];
            if (target.has_monitor_id == 0 or target.monitor_id != target_monitor.monitor_id) {
                output.outcome = outcome_invalid_target;
                return status_ok;
            }
            if (uuidEq(workspaces[source_index].workspace_id, target.workspace_id)) {
                output.outcome = outcome_noop;
                return status_ok;
            }
            return commitTransferPlan(
                output,
                &workspaces[source_index],
                target,
                subject_window,
                input.focused_token,
                input.follow_focus != 0,
                true,
                false,
            );
        },
        else => return status_invalid_argument,
    }
}

pub export fn omniwm_workspace_navigation_plan(
    input_ptr: ?*const Input,
    monitors_ptr: ?[*]const MonitorSnapshot,
    monitor_count: usize,
    workspaces_ptr: ?[*]const WorkspaceSnapshot,
    workspace_count: usize,
    output_ptr: ?*Output,
) i32 {
    const input = input_ptr orelse return status_invalid_argument;
    const output = output_ptr orelse return status_invalid_argument;
    if (monitor_count > 0 and monitors_ptr == null) return status_invalid_argument;
    if (workspace_count > 0 and workspaces_ptr == null) return status_invalid_argument;

    resetOutput(output);

    const monitors = if (monitor_count == 0)
        &[_]MonitorSnapshot{}
    else
        monitors_ptr.?[0..monitor_count];
    const workspaces = if (workspace_count == 0)
        &[_]WorkspaceSnapshot{}
    else
        workspaces_ptr.?[0..workspace_count];

    return plan(input.*, monitors, workspaces, output);
}

test "explicit switch targets workspace handoff and saves current workspace" {
    var save_workspaces = [_]UUID{zeroUUID(), zeroUUID()};
    var affected_workspaces = [_]UUID{zeroUUID(), zeroUUID()};
    var affected_monitors = [_]u32{0, 0};
    var output = Output{
        .outcome = 0,
        .subject_kind = 0,
        .focus_action = 0,
        .source_workspace_id = zeroUUID(),
        .target_workspace_id = zeroUUID(),
        .source_monitor_id = 0,
        .target_monitor_id = 0,
        .subject_token = zeroToken(),
        .save_workspace_ids = &save_workspaces,
        .save_workspace_capacity = save_workspaces.len,
        .save_workspace_count = 0,
        .affected_workspace_ids = &affected_workspaces,
        .affected_workspace_capacity = affected_workspaces.len,
        .affected_workspace_count = 0,
        .affected_monitor_ids = &affected_monitors,
        .affected_monitor_capacity = affected_monitors.len,
        .affected_monitor_count = 0,
        .has_source_workspace_id = 0,
        .has_target_workspace_id = 0,
        .has_source_monitor_id = 0,
        .has_target_monitor_id = 0,
        .has_subject_token = 0,
        .should_activate_target_workspace = 0,
        .should_set_interaction_monitor = 0,
        .should_sync_monitors_to_niri = 0,
        .should_hide_focus_border = 0,
        .should_commit_workspace_transition = 0,
    };
    const ws1 = UUID{ .high = 1, .low = 1 };
    const ws2 = UUID{ .high = 2, .low = 2 };
    const monitors = [_]MonitorSnapshot{
        .{
            .monitor_id = 11,
            .frame_min_x = 0,
            .frame_max_y = 1080,
            .center_x = 960,
            .center_y = 540,
            .active_workspace_id = ws1,
            .previous_workspace_id = zeroUUID(),
            .has_active_workspace_id = 1,
            .has_previous_workspace_id = 0,
        },
    };
    const workspaces = [_]WorkspaceSnapshot{
        .{
            .workspace_id = ws1,
            .monitor_id = 11,
            .layout_kind = layout_niri,
            .numeric_name = 1,
            .has_monitor_id = 1,
            .has_numeric_name = 1,
            .is_empty = 0,
        },
        .{
            .workspace_id = ws2,
            .monitor_id = 11,
            .layout_kind = layout_niri,
            .numeric_name = 2,
            .has_monitor_id = 1,
            .has_numeric_name = 1,
            .is_empty = 1,
        },
    };
    const input = Input{
        .operation = op_switch_workspace_explicit,
        .direction = direction_right,
        .current_workspace_id = ws1,
        .source_workspace_id = zeroUUID(),
        .target_workspace_id = ws2,
        .current_monitor_id = 11,
        .previous_monitor_id = 0,
        .subject_token = zeroToken(),
        .focused_token = zeroToken(),
        .selected_token = zeroToken(),
        .has_current_workspace_id = 1,
        .has_source_workspace_id = 0,
        .has_target_workspace_id = 1,
        .has_current_monitor_id = 1,
        .has_previous_monitor_id = 0,
        .has_subject_token = 0,
        .has_focused_token = 0,
        .has_selected_token = 0,
        .wrap_around = 0,
        .follow_focus = 0,
    };

    const status = omniwm_workspace_navigation_plan(
        &input,
        &monitors,
        monitors.len,
        &workspaces,
        workspaces.len,
        &output,
    );

    try std.testing.expectEqual(status_ok, status);
    try std.testing.expectEqual(outcome_execute, output.outcome);
    try std.testing.expectEqual(focus_workspace_handoff, output.focus_action);
    try std.testing.expectEqual(@as(u8, 1), output.should_hide_focus_border);
    try std.testing.expectEqual(@as(u8, 1), output.should_commit_workspace_transition);
    try std.testing.expectEqual(@as(usize, 1), output.save_workspace_count);
    try std.testing.expect(uuidEq(save_workspaces[0], ws1));
    try std.testing.expect(uuidEq(output.target_workspace_id, ws2));
    try std.testing.expectEqual(@as(u32, 11), output.target_monitor_id);
}

test "adjacent window move plans source recovery and both affected workspaces" {
    var save_workspaces = [_]UUID{zeroUUID(), zeroUUID()};
    var affected_workspaces = [_]UUID{zeroUUID(), zeroUUID()};
    var affected_monitors = [_]u32{0, 0};
    var output = Output{
        .outcome = 0,
        .subject_kind = 0,
        .focus_action = 0,
        .source_workspace_id = zeroUUID(),
        .target_workspace_id = zeroUUID(),
        .source_monitor_id = 0,
        .target_monitor_id = 0,
        .subject_token = zeroToken(),
        .save_workspace_ids = &save_workspaces,
        .save_workspace_capacity = save_workspaces.len,
        .save_workspace_count = 0,
        .affected_workspace_ids = &affected_workspaces,
        .affected_workspace_capacity = affected_workspaces.len,
        .affected_workspace_count = 0,
        .affected_monitor_ids = &affected_monitors,
        .affected_monitor_capacity = affected_monitors.len,
        .affected_monitor_count = 0,
        .has_source_workspace_id = 0,
        .has_target_workspace_id = 0,
        .has_source_monitor_id = 0,
        .has_target_monitor_id = 0,
        .has_subject_token = 0,
        .should_activate_target_workspace = 0,
        .should_set_interaction_monitor = 0,
        .should_sync_monitors_to_niri = 0,
        .should_hide_focus_border = 0,
        .should_commit_workspace_transition = 0,
    };
    const ws1 = UUID{ .high = 1, .low = 1 };
    const ws2 = UUID{ .high = 2, .low = 2 };
    const token = WindowToken{ .pid = 7, .window_id = 99 };
    const monitors = [_]MonitorSnapshot{
        .{
            .monitor_id = 11,
            .frame_min_x = 0,
            .frame_max_y = 1080,
            .center_x = 960,
            .center_y = 540,
            .active_workspace_id = ws1,
            .previous_workspace_id = zeroUUID(),
            .has_active_workspace_id = 1,
            .has_previous_workspace_id = 0,
        },
    };
    const workspaces = [_]WorkspaceSnapshot{
        .{
            .workspace_id = ws1,
            .monitor_id = 11,
            .layout_kind = layout_niri,
            .numeric_name = 1,
            .has_monitor_id = 1,
            .has_numeric_name = 1,
            .is_empty = 0,
        },
        .{
            .workspace_id = ws2,
            .monitor_id = 11,
            .layout_kind = layout_dwindle,
            .numeric_name = 2,
            .has_monitor_id = 1,
            .has_numeric_name = 1,
            .is_empty = 1,
        },
    };
    const input = Input{
        .operation = op_move_window_adjacent,
        .direction = direction_down,
        .current_workspace_id = ws1,
        .source_workspace_id = ws1,
        .target_workspace_id = zeroUUID(),
        .current_monitor_id = 11,
        .previous_monitor_id = 0,
        .subject_token = zeroToken(),
        .focused_token = token,
        .selected_token = zeroToken(),
        .has_current_workspace_id = 1,
        .has_source_workspace_id = 1,
        .has_target_workspace_id = 0,
        .has_current_monitor_id = 1,
        .has_previous_monitor_id = 0,
        .has_subject_token = 0,
        .has_focused_token = 1,
        .has_selected_token = 0,
        .wrap_around = 0,
        .follow_focus = 0,
    };

    const status = omniwm_workspace_navigation_plan(
        &input,
        &monitors,
        monitors.len,
        &workspaces,
        workspaces.len,
        &output,
    );

    try std.testing.expectEqual(status_ok, status);
    try std.testing.expectEqual(outcome_execute, output.outcome);
    try std.testing.expectEqual(subject_window, output.subject_kind);
    try std.testing.expect(tokenEq(output.subject_token, token));
    try std.testing.expectEqual(focus_recover_source, output.focus_action);
    try std.testing.expectEqual(@as(usize, 1), output.save_workspace_count);
    try std.testing.expectEqual(@as(usize, 2), output.affected_workspace_count);
    try std.testing.expect(uuidEq(output.source_workspace_id, ws1));
    try std.testing.expect(uuidEq(output.target_workspace_id, ws2));
}

test "wrong-monitor move target returns invalid target" {
    var save_workspaces = [_]UUID{zeroUUID()};
    var affected_workspaces = [_]UUID{zeroUUID()};
    var affected_monitors = [_]u32{0};
    var output = Output{
        .outcome = 0,
        .subject_kind = 0,
        .focus_action = 0,
        .source_workspace_id = zeroUUID(),
        .target_workspace_id = zeroUUID(),
        .source_monitor_id = 0,
        .target_monitor_id = 0,
        .subject_token = zeroToken(),
        .save_workspace_ids = &save_workspaces,
        .save_workspace_capacity = save_workspaces.len,
        .save_workspace_count = 0,
        .affected_workspace_ids = &affected_workspaces,
        .affected_workspace_capacity = affected_workspaces.len,
        .affected_workspace_count = 0,
        .affected_monitor_ids = &affected_monitors,
        .affected_monitor_capacity = affected_monitors.len,
        .affected_monitor_count = 0,
        .has_source_workspace_id = 0,
        .has_target_workspace_id = 0,
        .has_source_monitor_id = 0,
        .has_target_monitor_id = 0,
        .has_subject_token = 0,
        .should_activate_target_workspace = 0,
        .should_set_interaction_monitor = 0,
        .should_sync_monitors_to_niri = 0,
        .should_hide_focus_border = 0,
        .should_commit_workspace_transition = 0,
    };
    const ws1 = UUID{ .high = 1, .low = 1 };
    const ws2 = UUID{ .high = 2, .low = 2 };
    const monitors = [_]MonitorSnapshot{
        .{
            .monitor_id = 11,
            .frame_min_x = 0,
            .frame_max_y = 1080,
            .center_x = 960,
            .center_y = 540,
            .active_workspace_id = ws1,
            .previous_workspace_id = zeroUUID(),
            .has_active_workspace_id = 1,
            .has_previous_workspace_id = 0,
        },
        .{
            .monitor_id = 22,
            .frame_min_x = 1920,
            .frame_max_y = 1080,
            .center_x = 2880,
            .center_y = 540,
            .active_workspace_id = zeroUUID(),
            .previous_workspace_id = zeroUUID(),
            .has_active_workspace_id = 0,
            .has_previous_workspace_id = 0,
        },
    };
    const workspaces = [_]WorkspaceSnapshot{
        .{
            .workspace_id = ws1,
            .monitor_id = 11,
            .layout_kind = layout_niri,
            .numeric_name = 1,
            .has_monitor_id = 1,
            .has_numeric_name = 1,
            .is_empty = 0,
        },
        .{
            .workspace_id = ws2,
            .monitor_id = 11,
            .layout_kind = layout_niri,
            .numeric_name = 2,
            .has_monitor_id = 1,
            .has_numeric_name = 1,
            .is_empty = 1,
        },
    };
    const input = Input{
        .operation = op_move_window_to_workspace_on_monitor,
        .direction = direction_right,
        .current_workspace_id = ws1,
        .source_workspace_id = ws1,
        .target_workspace_id = ws2,
        .current_monitor_id = 11,
        .previous_monitor_id = 0,
        .subject_token = zeroToken(),
        .focused_token = WindowToken{ .pid = 9, .window_id = 901 },
        .selected_token = zeroToken(),
        .has_current_workspace_id = 1,
        .has_source_workspace_id = 1,
        .has_target_workspace_id = 1,
        .has_current_monitor_id = 1,
        .has_previous_monitor_id = 0,
        .has_subject_token = 0,
        .has_focused_token = 1,
        .has_selected_token = 0,
        .wrap_around = 0,
        .follow_focus = 1,
    };

    const status = omniwm_workspace_navigation_plan(
        &input,
        &monitors,
        monitors.len,
        &workspaces,
        workspaces.len,
        &output,
    );

    try std.testing.expectEqual(status_ok, status);
    try std.testing.expectEqual(outcome_invalid_target, output.outcome);
}

test "relative workspace boundary still requests focus border hide" {
    var save_workspaces = [_]UUID{zeroUUID()};
    var affected_workspaces = [_]UUID{zeroUUID()};
    var affected_monitors = [_]u32{0};
    var output = Output{
        .outcome = 0,
        .subject_kind = 0,
        .focus_action = 0,
        .source_workspace_id = zeroUUID(),
        .target_workspace_id = zeroUUID(),
        .source_monitor_id = 0,
        .target_monitor_id = 0,
        .subject_token = zeroToken(),
        .save_workspace_ids = &save_workspaces,
        .save_workspace_capacity = save_workspaces.len,
        .save_workspace_count = 0,
        .affected_workspace_ids = &affected_workspaces,
        .affected_workspace_capacity = affected_workspaces.len,
        .affected_workspace_count = 0,
        .affected_monitor_ids = &affected_monitors,
        .affected_monitor_capacity = affected_monitors.len,
        .affected_monitor_count = 0,
        .has_source_workspace_id = 0,
        .has_target_workspace_id = 0,
        .has_source_monitor_id = 0,
        .has_target_monitor_id = 0,
        .has_subject_token = 0,
        .should_activate_target_workspace = 0,
        .should_set_interaction_monitor = 0,
        .should_sync_monitors_to_niri = 0,
        .should_hide_focus_border = 0,
        .should_commit_workspace_transition = 0,
    };
    const ws1 = UUID{ .high = 1, .low = 1 };
    const monitors = [_]MonitorSnapshot{
        .{
            .monitor_id = 11,
            .frame_min_x = 0,
            .frame_max_y = 1080,
            .center_x = 960,
            .center_y = 540,
            .active_workspace_id = ws1,
            .previous_workspace_id = zeroUUID(),
            .has_active_workspace_id = 1,
            .has_previous_workspace_id = 0,
        },
    };
    const workspaces = [_]WorkspaceSnapshot{
        .{
            .workspace_id = ws1,
            .monitor_id = 11,
            .layout_kind = layout_niri,
            .numeric_name = 1,
            .has_monitor_id = 1,
            .has_numeric_name = 1,
            .is_empty = 0,
        },
    };
    const input = Input{
        .operation = op_switch_workspace_relative,
        .direction = direction_right,
        .current_workspace_id = ws1,
        .source_workspace_id = zeroUUID(),
        .target_workspace_id = zeroUUID(),
        .current_monitor_id = 11,
        .previous_monitor_id = 0,
        .subject_token = zeroToken(),
        .focused_token = zeroToken(),
        .selected_token = zeroToken(),
        .has_current_workspace_id = 1,
        .has_source_workspace_id = 0,
        .has_target_workspace_id = 0,
        .has_current_monitor_id = 1,
        .has_previous_monitor_id = 0,
        .has_subject_token = 0,
        .has_focused_token = 0,
        .has_selected_token = 0,
        .wrap_around = 0,
        .follow_focus = 0,
    };

    const status = omniwm_workspace_navigation_plan(
        &input,
        &monitors,
        monitors.len,
        &workspaces,
        workspaces.len,
        &output,
    );

    try std.testing.expectEqual(status_ok, status);
    try std.testing.expectEqual(outcome_noop, output.outcome);
    try std.testing.expectEqual(@as(u8, 1), output.should_hide_focus_border);
}

test "explicit window move does not request source workspace save" {
    var save_workspaces = [_]UUID{zeroUUID()};
    var affected_workspaces = [_]UUID{zeroUUID(), zeroUUID()};
    var affected_monitors = [_]u32{0, 0};
    var output = Output{
        .outcome = 0,
        .subject_kind = 0,
        .focus_action = 0,
        .source_workspace_id = zeroUUID(),
        .target_workspace_id = zeroUUID(),
        .source_monitor_id = 0,
        .target_monitor_id = 0,
        .subject_token = zeroToken(),
        .save_workspace_ids = &save_workspaces,
        .save_workspace_capacity = save_workspaces.len,
        .save_workspace_count = 0,
        .affected_workspace_ids = &affected_workspaces,
        .affected_workspace_capacity = affected_workspaces.len,
        .affected_workspace_count = 0,
        .affected_monitor_ids = &affected_monitors,
        .affected_monitor_capacity = affected_monitors.len,
        .affected_monitor_count = 0,
        .has_source_workspace_id = 0,
        .has_target_workspace_id = 0,
        .has_source_monitor_id = 0,
        .has_target_monitor_id = 0,
        .has_subject_token = 0,
        .should_activate_target_workspace = 0,
        .should_set_interaction_monitor = 0,
        .should_sync_monitors_to_niri = 0,
        .should_hide_focus_border = 0,
        .should_commit_workspace_transition = 0,
    };
    const ws1 = UUID{ .high = 1, .low = 1 };
    const ws2 = UUID{ .high = 2, .low = 2 };
    const token = WindowToken{ .pid = 7, .window_id = 77 };
    const monitors = [_]MonitorSnapshot{
        .{
            .monitor_id = 11,
            .frame_min_x = 0,
            .frame_max_y = 1080,
            .center_x = 960,
            .center_y = 540,
            .active_workspace_id = ws1,
            .previous_workspace_id = zeroUUID(),
            .has_active_workspace_id = 1,
            .has_previous_workspace_id = 0,
        },
        .{
            .monitor_id = 12,
            .frame_min_x = 1920,
            .frame_max_y = 1080,
            .center_x = 2880,
            .center_y = 540,
            .active_workspace_id = ws2,
            .previous_workspace_id = zeroUUID(),
            .has_active_workspace_id = 1,
            .has_previous_workspace_id = 0,
        },
    };
    const workspaces = [_]WorkspaceSnapshot{
        .{
            .workspace_id = ws1,
            .monitor_id = 11,
            .layout_kind = layout_niri,
            .numeric_name = 1,
            .has_monitor_id = 1,
            .has_numeric_name = 1,
            .is_empty = 0,
        },
        .{
            .workspace_id = ws2,
            .monitor_id = 12,
            .layout_kind = layout_niri,
            .numeric_name = 2,
            .has_monitor_id = 1,
            .has_numeric_name = 1,
            .is_empty = 0,
        },
    };
    const input = Input{
        .operation = op_move_window_explicit,
        .direction = direction_right,
        .current_workspace_id = zeroUUID(),
        .source_workspace_id = ws1,
        .target_workspace_id = ws2,
        .current_monitor_id = 0,
        .previous_monitor_id = 0,
        .subject_token = zeroToken(),
        .focused_token = token,
        .selected_token = zeroToken(),
        .has_current_workspace_id = 0,
        .has_source_workspace_id = 1,
        .has_target_workspace_id = 1,
        .has_current_monitor_id = 0,
        .has_previous_monitor_id = 0,
        .has_subject_token = 0,
        .has_focused_token = 1,
        .has_selected_token = 0,
        .wrap_around = 0,
        .follow_focus = 0,
    };

    const status = omniwm_workspace_navigation_plan(
        &input,
        &monitors,
        monitors.len,
        &workspaces,
        workspaces.len,
        &output,
    );

    try std.testing.expectEqual(status_ok, status);
    try std.testing.expectEqual(outcome_execute, output.outcome);
    try std.testing.expectEqual(@as(usize, 0), output.save_workspace_count);
    try std.testing.expectEqual(@as(usize, 2), output.affected_workspace_count);
}
