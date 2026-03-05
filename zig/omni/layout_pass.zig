const abi = @import("abi_types.zig");
const geometry = @import("geometry.zig");
const axis_solver = @import("axis_solver.zig");

const Rect = geometry.Rect;

fn parseNiriOrientation(orientation: u8) ?u8 {
    return switch (orientation) {
        abi.OMNI_NIRI_ORIENTATION_HORIZONTAL, abi.OMNI_NIRI_ORIENTATION_VERTICAL => orientation,
        else => null,
    };
}

fn isValidNiriSizingMode(mode: u8) bool {
    return mode == abi.OMNI_NIRI_SIZING_NORMAL or mode == abi.OMNI_NIRI_SIZING_FULLSCREEN;
}

fn makeHiddenColumnRect(
    side: u8,
    hidden_span: f64,
    working_height: f64,
    view_x: f64,
    view_y: f64,
    view_width: f64,
    view_height: f64,
    workspace_offset: f64,
    scale: f64,
) Rect {
    const edge_reveal = 1.0 / @max(1.0, scale);
    const x = if (side == abi.OMNI_NIRI_HIDE_LEFT)
        view_x - hidden_span + edge_reveal
    else
        view_x + view_width - edge_reveal;

    return .{
        .x = x + workspace_offset,
        .y = view_y + view_height - 2.0,
        .width = hidden_span,
        .height = working_height,
    };
}

fn makeHiddenRowRect(
    working_width: f64,
    hidden_span: f64,
    view_x: f64,
    view_y: f64,
    view_width: f64,
    view_height: f64,
    workspace_offset: f64,
) Rect {
    return .{
        .x = view_x + view_width - 2.0 + workspace_offset,
        .y = view_y + view_height - 2.0,
        .width = working_width,
        .height = hidden_span,
    };
}

fn solveAndLayoutNiriColumn(
    col: abi.OmniNiriColumnInput,
    windows: [*c]const abi.OmniNiriWindowInput,
    window_count: usize,
    secondary_gap: f64,
    orientation: u8,
    container_rect: Rect,
    fullscreen_rect: Rect,
    container_render_x: f64,
    container_render_y: f64,
    scale: f64,
    hide_side: u8,
    column_index: usize,
    out_windows: [*c]abi.OmniNiriWindowOutput,
) i32 {
    if (!geometry.isSubrangeWithinTotal(window_count, col.window_start, col.window_count)) {
        return abi.OMNI_ERR_OUT_OF_RANGE;
    }
    if (col.window_count == 0) return abi.OMNI_OK;
    if (col.window_count > abi.MAX_WINDOWS) return abi.OMNI_ERR_OUT_OF_RANGE;

    const tab_offset: f64 = if (col.is_tabbed != 0) col.tab_indicator_width else 0.0;
    const content_rect = Rect{
        .x = container_rect.x + tab_offset,
        .y = container_rect.y,
        .width = @max(0.0, container_rect.width - tab_offset),
        .height = container_rect.height,
    };

    const available_space = if (orientation == abi.OMNI_NIRI_ORIENTATION_HORIZONTAL)
        content_rect.height
    else
        content_rect.width;

    var axis_inputs: [abi.MAX_WINDOWS]abi.OmniAxisInput = undefined;
    var axis_outputs: [abi.MAX_WINDOWS]abi.OmniAxisOutput = undefined;

    for (0..col.window_count) |local_idx| {
        const global_idx = col.window_start + local_idx;
        const w = windows[global_idx];
        if (!isValidNiriSizingMode(w.sizing_mode)) return abi.OMNI_ERR_INVALID_ARGS;

        axis_inputs[local_idx] = .{
            .weight = w.weight,
            .min_constraint = w.min_constraint,
            .max_constraint = w.max_constraint,
            .has_max_constraint = w.has_max_constraint,
            .is_constraint_fixed = w.is_constraint_fixed,
            .has_fixed_value = w.has_fixed_value,
            .fixed_value = w.fixed_value,
        };
    }

    if (col.is_tabbed != 0) {
        axis_solver.solveTabbedImpl(
            axis_inputs[0..].ptr,
            col.window_count,
            available_space,
            axis_outputs[0..].ptr,
        );
    } else {
        axis_solver.solveNormal(
            axis_inputs[0..].ptr,
            col.window_count,
            available_space,
            secondary_gap,
            axis_outputs[0..].ptr,
        );
    }

    var pos: f64 = if (orientation == abi.OMNI_NIRI_ORIENTATION_HORIZONTAL)
        content_rect.y
    else
        content_rect.x;

    for (0..col.window_count) |local_idx| {
        const global_idx = col.window_start + local_idx;
        const w = windows[global_idx];
        const span = axis_outputs[local_idx].value;

        const base_rect_unrounded: Rect = if (w.sizing_mode == abi.OMNI_NIRI_SIZING_FULLSCREEN)
            fullscreen_rect
        else if (orientation == abi.OMNI_NIRI_ORIENTATION_HORIZONTAL)
            .{
                .x = content_rect.x,
                .y = if (col.is_tabbed != 0) content_rect.y else pos,
                .width = content_rect.width,
                .height = span,
            }
        else
            .{
                .x = if (col.is_tabbed != 0) content_rect.x else pos,
                .y = content_rect.y,
                .width = span,
                .height = content_rect.height,
            };

        const base_rect = geometry.roundRectToPhysicalPixels(base_rect_unrounded, scale);
        const animated_rect = geometry.roundRectToPhysicalPixels(
            .{
                .x = base_rect.x + container_render_x + w.render_offset_x,
                .y = base_rect.y + container_render_y + w.render_offset_y,
                .width = base_rect.width,
                .height = base_rect.height,
            },
            scale,
        );

        out_windows[global_idx] = .{
            .frame_x = base_rect.x,
            .frame_y = base_rect.y,
            .frame_width = base_rect.width,
            .frame_height = base_rect.height,
            .animated_x = animated_rect.x,
            .animated_y = animated_rect.y,
            .animated_width = animated_rect.width,
            .animated_height = animated_rect.height,
            .resolved_span = span,
            .was_constrained = axis_outputs[local_idx].was_constrained,
            .hide_side = hide_side,
            .column_index = column_index,
        };

        if (col.is_tabbed == 0) {
            pos += span;
            if (local_idx < col.window_count - 1) {
                pos += secondary_gap;
            }
        }
    }

    return abi.OMNI_OK;
}

pub fn omni_niri_layout_pass_impl(
    columns: [*c]const abi.OmniNiriColumnInput,
    column_count: usize,
    windows: [*c]const abi.OmniNiriWindowInput,
    window_count: usize,
    working_x: f64,
    working_y: f64,
    working_width: f64,
    working_height: f64,
    view_x: f64,
    view_y: f64,
    view_width: f64,
    view_height: f64,
    fullscreen_x: f64,
    fullscreen_y: f64,
    fullscreen_width: f64,
    fullscreen_height: f64,
    primary_gap: f64,
    secondary_gap: f64,
    view_start: f64,
    viewport_span: f64,
    workspace_offset: f64,
    scale: f64,
    orientation: u8,
    out_windows: [*c]abi.OmniNiriWindowOutput,
    out_window_count: usize,
) i32 {
    return omni_niri_layout_pass_v2_impl(
        columns,
        column_count,
        windows,
        window_count,
        working_x,
        working_y,
        working_width,
        working_height,
        view_x,
        view_y,
        view_width,
        view_height,
        fullscreen_x,
        fullscreen_y,
        fullscreen_width,
        fullscreen_height,
        primary_gap,
        secondary_gap,
        view_start,
        viewport_span,
        workspace_offset,
        scale,
        orientation,
        out_windows,
        out_window_count,
        null,
        0,
    );
}

pub fn omni_niri_layout_pass_v2_impl(
    columns: [*c]const abi.OmniNiriColumnInput,
    column_count: usize,
    windows: [*c]const abi.OmniNiriWindowInput,
    window_count: usize,
    working_x: f64,
    working_y: f64,
    working_width: f64,
    working_height: f64,
    view_x: f64,
    view_y: f64,
    view_width: f64,
    view_height: f64,
    fullscreen_x: f64,
    fullscreen_y: f64,
    fullscreen_width: f64,
    fullscreen_height: f64,
    primary_gap: f64,
    secondary_gap: f64,
    view_start: f64,
    viewport_span: f64,
    workspace_offset: f64,
    scale: f64,
    orientation: u8,
    out_windows: [*c]abi.OmniNiriWindowOutput,
    out_window_count: usize,
    out_columns: [*c]abi.OmniNiriColumnOutput,
    out_column_count: usize,
) i32 {
    if (out_windows == null and out_window_count != 0) return abi.OMNI_ERR_INVALID_ARGS;
    if (window_count > 0 and out_windows == null) return abi.OMNI_ERR_INVALID_ARGS;
    if (out_window_count < window_count) return abi.OMNI_ERR_INVALID_ARGS;
    if (column_count > 0 and columns == null) return abi.OMNI_ERR_INVALID_ARGS;
    if (window_count > 0 and windows == null) return abi.OMNI_ERR_INVALID_ARGS;
    if (out_column_count > 0 and out_columns == null) return abi.OMNI_ERR_INVALID_ARGS;
    if (out_column_count > 0 and out_column_count < column_count) return abi.OMNI_ERR_INVALID_ARGS;

    const parsed_orientation = parseNiriOrientation(orientation) orelse return abi.OMNI_ERR_INVALID_ARGS;

    for (0..window_count) |i| {
        out_windows[i] = .{
            .frame_x = 0.0,
            .frame_y = 0.0,
            .frame_width = 0.0,
            .frame_height = 0.0,
            .animated_x = 0.0,
            .animated_y = 0.0,
            .animated_width = 0.0,
            .animated_height = 0.0,
            .resolved_span = 0.0,
            .was_constrained = 0,
            .hide_side = abi.OMNI_NIRI_HIDE_NONE,
            .column_index = 0,
        };
    }

    if (out_columns != null and out_column_count > 0) {
        for (0..column_count) |i| {
            out_columns[i] = .{
                .frame_x = 0.0,
                .frame_y = 0.0,
                .frame_width = 0.0,
                .frame_height = 0.0,
                .hide_side = abi.OMNI_NIRI_HIDE_NONE,
                .is_visible = 0,
            };
        }
    }

    if (column_count == 0) {
        return if (window_count == 0) abi.OMNI_OK else abi.OMNI_ERR_OUT_OF_RANGE;
    }

    for (0..column_count) |idx| {
        const col = columns[idx];
        if (!geometry.isSubrangeWithinTotal(window_count, col.window_start, col.window_count)) {
            return abi.OMNI_ERR_OUT_OF_RANGE;
        }
    }

    for (0..window_count) |window_idx| {
        var owner_count: usize = 0;
        for (0..column_count) |column_idx| {
            const col = columns[column_idx];
            if (geometry.rangeContains(col.window_start, col.window_count, window_idx)) {
                owner_count += 1;
                if (owner_count > 1) return abi.OMNI_ERR_OUT_OF_RANGE;
            }
        }
        if (owner_count == 0) return abi.OMNI_ERR_OUT_OF_RANGE;
    }

    const fullscreen_rect = Rect{
        .x = fullscreen_x,
        .y = fullscreen_y,
        .width = fullscreen_width,
        .height = fullscreen_height,
    };

    const view_end = view_start + viewport_span;
    var running_pos: f64 = 0.0;
    var total_span: f64 = 0.0;

    for (0..column_count) |idx| {
        const col = columns[idx];

        const container_pos = running_pos;
        const container_span = col.span;
        const container_end = container_pos + container_span;
        const is_visible = container_end > view_start and container_pos < view_end;

        if (is_visible) {
            const container_rect = if (parsed_orientation == abi.OMNI_NIRI_ORIENTATION_HORIZONTAL)
                geometry.roundRectToPhysicalPixels(
                    .{
                        .x = working_x + container_pos - view_start + col.render_offset_x + workspace_offset,
                        .y = working_y,
                        .width = geometry.roundToPhysicalPixel(container_span, scale),
                        .height = working_height,
                    },
                    scale,
                )
            else
                geometry.roundRectToPhysicalPixels(
                    .{
                        .x = working_x + workspace_offset,
                        .y = working_y + container_pos - view_start + col.render_offset_y,
                        .width = working_width,
                        .height = geometry.roundToPhysicalPixel(container_span, scale),
                    },
                    scale,
                );

            if (out_columns != null and out_column_count >= column_count) {
                out_columns[idx] = .{
                    .frame_x = container_rect.x,
                    .frame_y = container_rect.y,
                    .frame_width = container_rect.width,
                    .frame_height = container_rect.height,
                    .hide_side = abi.OMNI_NIRI_HIDE_NONE,
                    .is_visible = 1,
                };
            }

            const rc = solveAndLayoutNiriColumn(
                col,
                windows,
                window_count,
                secondary_gap,
                parsed_orientation,
                container_rect,
                fullscreen_rect,
                col.render_offset_x,
                col.render_offset_y,
                scale,
                abi.OMNI_NIRI_HIDE_NONE,
                idx,
                out_windows,
            );
            if (rc != abi.OMNI_OK) return rc;
        }

        running_pos += container_span;
        total_span += container_span;
        if (idx < column_count - 1) {
            running_pos += primary_gap;
            total_span += primary_gap;
        }
    }

    const avg_span = total_span / @as(f64, @floatFromInt(@max(@as(usize, 1), column_count)));
    const hidden_span = geometry.roundToPhysicalPixel(@max(1.0, avg_span), scale);

    running_pos = 0.0;
    for (0..column_count) |idx| {
        const col = columns[idx];
        const container_pos = running_pos;
        const container_span = col.span;
        const container_end = container_pos + container_span;
        const is_visible = container_end > view_start and container_pos < view_end;

        if (!is_visible) {
            const hide_side: u8 = if (container_end <= view_start)
                abi.OMNI_NIRI_HIDE_LEFT
            else
                abi.OMNI_NIRI_HIDE_RIGHT;

            const container_rect_unrounded = if (parsed_orientation == abi.OMNI_NIRI_ORIENTATION_HORIZONTAL)
                makeHiddenColumnRect(
                    hide_side,
                    hidden_span,
                    working_height,
                    view_x,
                    view_y,
                    view_width,
                    view_height,
                    workspace_offset,
                    scale,
                )
            else
                makeHiddenRowRect(
                    working_width,
                    hidden_span,
                    view_x,
                    view_y,
                    view_width,
                    view_height,
                    workspace_offset,
                );
            const container_rect = geometry.roundRectToPhysicalPixels(container_rect_unrounded, scale);

            if (out_columns != null and out_column_count >= column_count) {
                out_columns[idx] = .{
                    .frame_x = container_rect.x,
                    .frame_y = container_rect.y,
                    .frame_width = container_rect.width,
                    .frame_height = container_rect.height,
                    .hide_side = hide_side,
                    .is_visible = 0,
                };
            }

            const rc = solveAndLayoutNiriColumn(
                col,
                windows,
                window_count,
                secondary_gap,
                parsed_orientation,
                container_rect,
                fullscreen_rect,
                0.0,
                0.0,
                scale,
                hide_side,
                idx,
                out_windows,
            );
            if (rc != abi.OMNI_OK) return rc;
        }

        running_pos += container_span;
        if (idx < column_count - 1) {
            running_pos += primary_gap;
        }
    }

    return abi.OMNI_OK;
}

test "layout pass allows null window output for zero-window snapshots" {
    const testing = @import("std").testing;

    var columns = [_]abi.OmniNiriColumnInput{
        .{
            .span = 120.0,
            .render_offset_x = 0.0,
            .render_offset_y = 0.0,
            .is_tabbed = 0,
            .tab_indicator_width = 0.0,
            .window_start = 0,
            .window_count = 0,
        },
    };
    var out_columns = [_]abi.OmniNiriColumnOutput{
        .{
            .frame_x = 0.0,
            .frame_y = 0.0,
            .frame_width = 0.0,
            .frame_height = 0.0,
            .hide_side = abi.OMNI_NIRI_HIDE_NONE,
            .is_visible = 0,
        },
    };

    const rc = omni_niri_layout_pass_v2_impl(
        &columns,
        columns.len,
        null,
        0,
        0.0,
        0.0,
        1920.0,
        1080.0,
        0.0,
        0.0,
        1920.0,
        1080.0,
        0.0,
        0.0,
        1920.0,
        1080.0,
        8.0,
        8.0,
        0.0,
        1920.0,
        0.0,
        1.0,
        abi.OMNI_NIRI_ORIENTATION_HORIZONTAL,
        null,
        0,
        &out_columns,
        out_columns.len,
    );

    try testing.expectEqual(@as(i32, abi.OMNI_OK), rc);
    try testing.expectEqual(@as(u8, 1), out_columns[0].is_visible);
}

test "layout pass rejects null window output when windows are present" {
    const testing = @import("std").testing;

    var columns = [_]abi.OmniNiriColumnInput{
        .{
            .span = 120.0,
            .render_offset_x = 0.0,
            .render_offset_y = 0.0,
            .is_tabbed = 0,
            .tab_indicator_width = 0.0,
            .window_start = 0,
            .window_count = 1,
        },
    };
    var windows = [_]abi.OmniNiriWindowInput{
        .{
            .weight = 1.0,
            .min_constraint = 0.0,
            .max_constraint = 0.0,
            .has_max_constraint = 0,
            .is_constraint_fixed = 0,
            .has_fixed_value = 0,
            .fixed_value = 0.0,
            .sizing_mode = abi.OMNI_NIRI_SIZING_NORMAL,
            .render_offset_x = 0.0,
            .render_offset_y = 0.0,
        },
    };

    const rc = omni_niri_layout_pass_v2_impl(
        &columns,
        columns.len,
        &windows,
        windows.len,
        0.0,
        0.0,
        1920.0,
        1080.0,
        0.0,
        0.0,
        1920.0,
        1080.0,
        0.0,
        0.0,
        1920.0,
        1080.0,
        8.0,
        8.0,
        0.0,
        1920.0,
        0.0,
        1.0,
        abi.OMNI_NIRI_ORIENTATION_HORIZONTAL,
        null,
        0,
        null,
        0,
    );

    try testing.expectEqual(@as(i32, abi.OMNI_ERR_INVALID_ARGS), rc);
}
