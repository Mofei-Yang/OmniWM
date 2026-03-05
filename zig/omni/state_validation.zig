const std = @import("std");
const abi = @import("abi_types.zig");
const geometry = @import("geometry.zig");

fn setColumnFailure(out_result: [*c]abi.OmniNiriStateValidationResult, idx: usize, rc: i32) i32 {
    out_result[0].first_invalid_column_index = std.math.cast(i64, idx) orelse -1;
    out_result[0].first_error_code = rc;
    return rc;
}

fn setWindowFailure(out_result: [*c]abi.OmniNiriStateValidationResult, idx: usize, rc: i32) i32 {
    out_result[0].first_invalid_window_index = std.math.cast(i64, idx) orelse -1;
    out_result[0].first_error_code = rc;
    return rc;
}

fn uuidEqual(a: abi.OmniUuid128, b: abi.OmniUuid128) bool {
    return std.mem.eql(u8, a.bytes[0..], b.bytes[0..]);
}

fn isValidSizeKind(kind: u8) bool {
    return kind == abi.OMNI_NIRI_SIZE_KIND_PROPORTION or kind == abi.OMNI_NIRI_SIZE_KIND_FIXED;
}

fn isValidHeightKind(kind: u8) bool {
    return kind == abi.OMNI_NIRI_HEIGHT_KIND_AUTO or kind == abi.OMNI_NIRI_HEIGHT_KIND_FIXED;
}

fn initValidationResult(
    out_result: [*c]abi.OmniNiriStateValidationResult,
    column_count: usize,
    window_count: usize,
) void {
    out_result[0] = .{
        .column_count = column_count,
        .window_count = window_count,
        .first_invalid_column_index = -1,
        .first_invalid_window_index = -1,
        .first_error_code = abi.OMNI_OK,
    };
}

pub fn omni_niri_validate_state_snapshot_basic_impl(
    columns: [*c]const abi.OmniNiriStateColumnInput,
    column_count: usize,
    windows: [*c]const abi.OmniNiriStateWindowInput,
    window_count: usize,
    out_result: [*c]abi.OmniNiriStateValidationResult,
) i32 {
    if (out_result == null) return abi.OMNI_ERR_INVALID_ARGS;
    if (column_count > 0 and columns == null) return abi.OMNI_ERR_INVALID_ARGS;
    if (window_count > 0 and windows == null) return abi.OMNI_ERR_INVALID_ARGS;

    initValidationResult(out_result, column_count, window_count);

    if (column_count == 0 and window_count > 0) {
        return setWindowFailure(out_result, 0, abi.OMNI_ERR_OUT_OF_RANGE);
    }

    for (0..column_count) |idx| {
        const col = columns[idx];
        if (!geometry.isSubrangeWithinTotal(window_count, col.window_start, col.window_count)) {
            return setColumnFailure(out_result, idx, abi.OMNI_ERR_OUT_OF_RANGE);
        }
        if (col.window_count > 0 and col.active_tile_idx >= col.window_count) {
            return setColumnFailure(out_result, idx, abi.OMNI_ERR_OUT_OF_RANGE);
        }
        if (!isValidSizeKind(col.width_kind)) {
            return setColumnFailure(out_result, idx, abi.OMNI_ERR_INVALID_ARGS);
        }
        if (col.is_full_width > 1) {
            return setColumnFailure(out_result, idx, abi.OMNI_ERR_INVALID_ARGS);
        }
        if (col.has_saved_width > 1) {
            return setColumnFailure(out_result, idx, abi.OMNI_ERR_INVALID_ARGS);
        }
        if (col.has_saved_width != 0 and !isValidSizeKind(col.saved_width_kind)) {
            return setColumnFailure(out_result, idx, abi.OMNI_ERR_INVALID_ARGS);
        }
    }

    for (0..window_count) |idx| {
        const win = windows[idx];
        if (win.column_index >= column_count) {
            return setWindowFailure(out_result, idx, abi.OMNI_ERR_OUT_OF_RANGE);
        }
        if (!isValidHeightKind(win.height_kind)) {
            return setWindowFailure(out_result, idx, abi.OMNI_ERR_INVALID_ARGS);
        }
    }

    return abi.OMNI_OK;
}

pub fn omni_niri_validate_state_snapshot_impl(
    columns: [*c]const abi.OmniNiriStateColumnInput,
    column_count: usize,
    windows: [*c]const abi.OmniNiriStateWindowInput,
    window_count: usize,
    out_result: [*c]abi.OmniNiriStateValidationResult,
) i32 {
    const basic_rc = omni_niri_validate_state_snapshot_basic_impl(
        columns,
        column_count,
        windows,
        window_count,
        out_result,
    );
    if (basic_rc != abi.OMNI_OK) {
        return basic_rc;
    }

    for (0..column_count) |i| {
        const col_i = columns[i];
        for (i + 1..column_count) |j| {
            if (uuidEqual(col_i.column_id, columns[j].column_id)) {
                return setColumnFailure(out_result, j, abi.OMNI_ERR_INVALID_ARGS);
            }
        }
    }

    // basic bounds were already validated above.

    for (0..window_count) |window_idx| {
        var owner: ?usize = null;
        for (0..column_count) |column_idx| {
            const col = columns[column_idx];
            if (!geometry.rangeContains(col.window_start, col.window_count, window_idx)) {
                continue;
            }

            if (owner == null) {
                owner = column_idx;
            } else {
                out_result[0].first_invalid_column_index = std.math.cast(i64, column_idx) orelse -1;
                out_result[0].first_invalid_window_index = std.math.cast(i64, window_idx) orelse -1;
                out_result[0].first_error_code = abi.OMNI_ERR_INVALID_ARGS;
                return abi.OMNI_ERR_INVALID_ARGS;
            }
        }

        if (owner == null) {
            out_result[0].first_invalid_window_index = std.math.cast(i64, window_idx) orelse -1;
            out_result[0].first_error_code = abi.OMNI_ERR_INVALID_ARGS;
            return abi.OMNI_ERR_INVALID_ARGS;
        }
    }

    for (0..window_count) |idx| {
        const win = windows[idx];
        const owner_column = columns[win.column_index];
        if (!geometry.rangeContains(owner_column.window_start, owner_column.window_count, idx)) {
            out_result[0].first_invalid_column_index = std.math.cast(i64, win.column_index) orelse -1;
            out_result[0].first_invalid_window_index = std.math.cast(i64, idx) orelse -1;
            out_result[0].first_error_code = abi.OMNI_ERR_INVALID_ARGS;
            return abi.OMNI_ERR_INVALID_ARGS;
        }

        if (!uuidEqual(win.column_id, owner_column.column_id)) {
            out_result[0].first_invalid_column_index = std.math.cast(i64, win.column_index) orelse -1;
            out_result[0].first_invalid_window_index = std.math.cast(i64, idx) orelse -1;
            out_result[0].first_error_code = abi.OMNI_ERR_INVALID_ARGS;
            return abi.OMNI_ERR_INVALID_ARGS;
        }
    }

    for (0..window_count) |i| {
        const win_i = windows[i];
        for (i + 1..window_count) |j| {
            if (uuidEqual(win_i.window_id, windows[j].window_id)) {
                return setWindowFailure(out_result, j, abi.OMNI_ERR_INVALID_ARGS);
            }
        }
    }

    return abi.OMNI_OK;
}

test "state validation rejects nonzero count with null pointer" {
    const testing = std.testing;

    var result: abi.OmniNiriStateValidationResult = undefined;
    const rc = omni_niri_validate_state_snapshot_impl(
        null,
        1,
        null,
        0,
        &result,
    );

    try testing.expectEqual(@as(i32, abi.OMNI_ERR_INVALID_ARGS), rc);
}
