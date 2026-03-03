import CZigLayout
import Foundation
import Testing

private let abiOK: Int32 = 0
private let abiErrInvalidArgs: Int32 = -1
private let abiErrOutOfRange: Int32 = -2

private func makeUUID(_ marker: UInt8) -> OmniUuid128 {
    var value = OmniUuid128()
    withUnsafeMutableBytes(of: &value) { raw in
        for idx in raw.indices {
            raw[idx] = 0
        }
        raw[0] = marker
    }
    return value
}

private func validateState(
    columns: [OmniNiriStateColumnInput],
    windows: [OmniNiriStateWindowInput]
) -> (rc: Int32, result: OmniNiriStateValidationResult) {
    var result = OmniNiriStateValidationResult(
        column_count: 0,
        window_count: 0,
        first_invalid_column_index: -1,
        first_invalid_window_index: -1,
        first_error_code: abiOK
    )

    let rc: Int32 = columns.withUnsafeBufferPointer { columnBuf in
        windows.withUnsafeBufferPointer { windowBuf in
            withUnsafeMutablePointer(to: &result) { resultPtr in
                omni_niri_validate_state_snapshot(
                    columnBuf.baseAddress,
                    columnBuf.count,
                    windowBuf.baseAddress,
                    windowBuf.count,
                    resultPtr
                )
            }
        }
    }

    return (rc: rc, result: result)
}

private func runLayoutPass(columns: [OmniNiriColumnInput], windows: [OmniNiriWindowInput]) -> Int32 {
    var outWindows = [OmniNiriWindowOutput](
        repeating: OmniNiriWindowOutput(
            frame_x: 0,
            frame_y: 0,
            frame_width: 0,
            frame_height: 0,
            animated_x: 0,
            animated_y: 0,
            animated_width: 0,
            animated_height: 0,
            resolved_span: 0,
            was_constrained: 0,
            hide_side: 0,
            column_index: 0
        ),
        count: windows.count
    )

    return columns.withUnsafeBufferPointer { columnBuf in
        windows.withUnsafeBufferPointer { windowBuf in
            outWindows.withUnsafeMutableBufferPointer { outBuf in
                omni_niri_layout_pass_v2(
                    columnBuf.baseAddress,
                    columnBuf.count,
                    windowBuf.baseAddress,
                    windowBuf.count,
                    0,
                    0,
                    1920,
                    1080,
                    0,
                    0,
                    1920,
                    1080,
                    0,
                    0,
                    1920,
                    1080,
                    16,
                    12,
                    0,
                    1920,
                    0,
                    2,
                    0,
                    outBuf.baseAddress,
                    outBuf.count,
                    nil,
                    0
                )
            }
        }
    }
}

@Suite struct NiriZigAbiValidationTests {
    @Test func layoutPassRejectsOverflowProneColumnRange() {
        let columns = [
            OmniNiriColumnInput(
                span: 600,
                render_offset_x: 0,
                render_offset_y: 0,
                is_tabbed: 0,
                tab_indicator_width: 0,
                window_start: Int.max,
                window_count: 1
            )
        ]
        let windows = [
            OmniNiriWindowInput(
                weight: 1,
                min_constraint: 1,
                max_constraint: 0,
                has_max_constraint: 0,
                is_constraint_fixed: 0,
                has_fixed_value: 0,
                fixed_value: 0,
                sizing_mode: 0,
                render_offset_x: 0,
                render_offset_y: 0
            )
        ]

        let rc = runLayoutPass(columns: columns, windows: windows)
        #expect(rc == abiErrOutOfRange)
    }

    @Test func stateValidationRejectsOverlappingCoverage() {
        let c0 = makeUUID(1)
        let c1 = makeUUID(2)
        let columns = [
            OmniNiriStateColumnInput(column_id: c0, window_start: 0, window_count: 2, active_tile_idx: 0, is_tabbed: 0, size_value: 1),
            OmniNiriStateColumnInput(column_id: c1, window_start: 1, window_count: 2, active_tile_idx: 0, is_tabbed: 0, size_value: 1)
        ]
        let windows = [
            OmniNiriStateWindowInput(window_id: makeUUID(10), column_id: c0, column_index: 0, size_value: 1),
            OmniNiriStateWindowInput(window_id: makeUUID(11), column_id: c0, column_index: 0, size_value: 1),
            OmniNiriStateWindowInput(window_id: makeUUID(12), column_id: c1, column_index: 1, size_value: 1)
        ]

        let outcome = validateState(columns: columns, windows: windows)
        #expect(outcome.rc == abiErrInvalidArgs)
        #expect(outcome.result.first_error_code == abiErrInvalidArgs)
    }

    @Test func stateValidationRejectsMissingCoverage() {
        let c0 = makeUUID(1)
        let c1 = makeUUID(2)
        let columns = [
            OmniNiriStateColumnInput(column_id: c0, window_start: 0, window_count: 1, active_tile_idx: 0, is_tabbed: 0, size_value: 1),
            OmniNiriStateColumnInput(column_id: c1, window_start: 2, window_count: 1, active_tile_idx: 0, is_tabbed: 0, size_value: 1)
        ]
        let windows = [
            OmniNiriStateWindowInput(window_id: makeUUID(10), column_id: c0, column_index: 0, size_value: 1),
            OmniNiriStateWindowInput(window_id: makeUUID(11), column_id: c0, column_index: 0, size_value: 1),
            OmniNiriStateWindowInput(window_id: makeUUID(12), column_id: c1, column_index: 1, size_value: 1)
        ]

        let outcome = validateState(columns: columns, windows: windows)
        #expect(outcome.rc == abiErrInvalidArgs)
        #expect(outcome.result.first_error_code == abiErrInvalidArgs)
    }

    @Test func stateValidationRejectsWindowColumnOwnershipMismatch() {
        let c0 = makeUUID(1)
        let c1 = makeUUID(2)
        let columns = [
            OmniNiriStateColumnInput(column_id: c0, window_start: 0, window_count: 1, active_tile_idx: 0, is_tabbed: 0, size_value: 1),
            OmniNiriStateColumnInput(column_id: c1, window_start: 1, window_count: 1, active_tile_idx: 0, is_tabbed: 0, size_value: 1)
        ]
        let windows = [
            OmniNiriStateWindowInput(window_id: makeUUID(10), column_id: c0, column_index: 1, size_value: 1),
            OmniNiriStateWindowInput(window_id: makeUUID(11), column_id: c1, column_index: 1, size_value: 1)
        ]

        let outcome = validateState(columns: columns, windows: windows)
        #expect(outcome.rc == abiErrInvalidArgs)
        #expect(outcome.result.first_error_code == abiErrInvalidArgs)
    }

    @Test func stateValidationRejectsWindowColumnIdMismatch() {
        let c0 = makeUUID(1)
        let c1 = makeUUID(2)
        let columns = [
            OmniNiriStateColumnInput(column_id: c0, window_start: 0, window_count: 1, active_tile_idx: 0, is_tabbed: 0, size_value: 1),
            OmniNiriStateColumnInput(column_id: c1, window_start: 1, window_count: 1, active_tile_idx: 0, is_tabbed: 0, size_value: 1)
        ]
        let windows = [
            OmniNiriStateWindowInput(window_id: makeUUID(10), column_id: c1, column_index: 0, size_value: 1),
            OmniNiriStateWindowInput(window_id: makeUUID(11), column_id: c1, column_index: 1, size_value: 1)
        ]

        let outcome = validateState(columns: columns, windows: windows)
        #expect(outcome.rc == abiErrInvalidArgs)
        #expect(outcome.result.first_error_code == abiErrInvalidArgs)
    }

    @Test func stateValidationRejectsDuplicateColumnIds() {
        let duplicate = makeUUID(7)
        let columns = [
            OmniNiriStateColumnInput(column_id: duplicate, window_start: 0, window_count: 1, active_tile_idx: 0, is_tabbed: 0, size_value: 1),
            OmniNiriStateColumnInput(column_id: duplicate, window_start: 1, window_count: 1, active_tile_idx: 0, is_tabbed: 0, size_value: 1)
        ]
        let windows = [
            OmniNiriStateWindowInput(window_id: makeUUID(10), column_id: duplicate, column_index: 0, size_value: 1),
            OmniNiriStateWindowInput(window_id: makeUUID(11), column_id: duplicate, column_index: 1, size_value: 1)
        ]

        let outcome = validateState(columns: columns, windows: windows)
        #expect(outcome.rc == abiErrInvalidArgs)
        #expect(outcome.result.first_error_code == abiErrInvalidArgs)
    }

    @Test func stateValidationRejectsDuplicateWindowIds() {
        let c0 = makeUUID(1)
        let c1 = makeUUID(2)
        let duplicateWindow = makeUUID(9)
        let columns = [
            OmniNiriStateColumnInput(column_id: c0, window_start: 0, window_count: 1, active_tile_idx: 0, is_tabbed: 0, size_value: 1),
            OmniNiriStateColumnInput(column_id: c1, window_start: 1, window_count: 1, active_tile_idx: 0, is_tabbed: 0, size_value: 1)
        ]
        let windows = [
            OmniNiriStateWindowInput(window_id: duplicateWindow, column_id: c0, column_index: 0, size_value: 1),
            OmniNiriStateWindowInput(window_id: duplicateWindow, column_id: c1, column_index: 1, size_value: 1)
        ]

        let outcome = validateState(columns: columns, windows: windows)
        #expect(outcome.rc == abiErrInvalidArgs)
        #expect(outcome.result.first_error_code == abiErrInvalidArgs)
    }
}
