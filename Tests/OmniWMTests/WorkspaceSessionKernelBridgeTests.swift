import COmniWMKernels
@testable import OmniWM
import Testing

@MainActor
struct WorkspaceSessionKernelBridgeTests {
    @Test func `validation returns kernel status error`() {
        let error = WorkspaceSessionKernel.workspaceSessionKernelValidationError(
            status: Int32(OMNIWM_KERNELS_STATUS_INVALID_ARGUMENT),
            rawOutput: omniwm_workspace_session_output(),
            monitorCapacity: 0,
            workspaceProjectionCapacity: 0,
            disconnectedCacheCapacity: 0
        )

        #expect(error == .kernelStatus(code: Int32(OMNIWM_KERNELS_STATUS_INVALID_ARGUMENT)))
    }

    @Test func `validation returns monitor overflow error`() {
        var output = omniwm_workspace_session_output()
        output.monitor_result_count = 2

        let error = WorkspaceSessionKernel.workspaceSessionKernelValidationError(
            status: Int32(OMNIWM_KERNELS_STATUS_OK),
            rawOutput: output,
            monitorCapacity: 1,
            workspaceProjectionCapacity: 0,
            disconnectedCacheCapacity: 0
        )

        #expect(error == .monitorResultsOverflow(reported: 2, capacity: 1))
    }

    @Test func `validation returns workspace projection overflow error`() {
        var output = omniwm_workspace_session_output()
        output.workspace_projection_count = 3

        let error = WorkspaceSessionKernel.workspaceSessionKernelValidationError(
            status: Int32(OMNIWM_KERNELS_STATUS_OK),
            rawOutput: output,
            monitorCapacity: 0,
            workspaceProjectionCapacity: 2,
            disconnectedCacheCapacity: 0
        )

        #expect(error == .workspaceProjectionOverflow(reported: 3, capacity: 2))
    }

    @Test func `validation returns disconnected cache overflow error`() {
        var output = omniwm_workspace_session_output()
        output.disconnected_cache_result_count = 4

        let error = WorkspaceSessionKernel.workspaceSessionKernelValidationError(
            status: Int32(OMNIWM_KERNELS_STATUS_OK),
            rawOutput: output,
            monitorCapacity: 0,
            workspaceProjectionCapacity: 0,
            disconnectedCacheCapacity: 3
        )

        #expect(error == .disconnectedCacheOverflow(reported: 4, capacity: 3))
    }

    @Test func `failure formatter includes operation and typed error`() {
        let message = WorkspaceSessionKernel.workspaceSessionKernelFailureMessage(
            for: .monitorResultsOverflow(reported: 2, capacity: 1),
            operation: "WorkspaceSessionKernel.project"
        )

        #expect(
            message ==
                "[WorkspaceSessionKernel] WorkspaceSessionKernel.project failed: omniwm_workspace_session_plan reported 2 monitor results for capacity 1"
        )
    }

    @Test func `logged adapter returns nil for failed result`() {
        let value: Int? = WorkspaceSessionKernel.logged(
            .failure(.kernelStatus(code: Int32(OMNIWM_KERNELS_STATUS_INVALID_ARGUMENT))),
            operation: "WorkspaceSessionKernel.project"
        )

        #expect(value == nil)
    }

    @Test func `outcome rejects unknown raw values with typed bridge error`() {
        do {
            _ = try WorkspaceSessionKernel.Outcome(kernelRawValue: 99)
            Issue.record("Expected an unknown raw value error for WorkspaceSessionKernel.Outcome")
        } catch let error as WorkspaceSessionKernel.WorkspaceSessionKernelError {
            #expect(error == .unknownRawValue(label: "WorkspaceSessionKernel.Outcome", value: 99))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func `patch viewport action rejects unknown raw values with typed bridge error`() {
        do {
            _ = try WorkspaceSessionKernel.PatchViewportAction(kernelRawValue: 99)
            Issue.record("Expected an unknown raw value error for WorkspaceSessionKernel.PatchViewportAction")
        } catch let error as WorkspaceSessionKernel.WorkspaceSessionKernelError {
            #expect(
                error ==
                    .unknownRawValue(label: "WorkspaceSessionKernel.PatchViewportAction", value: 99)
            )
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func `focus clear action rejects unknown raw values with typed bridge error`() {
        do {
            _ = try WorkspaceSessionKernel.FocusClearAction(kernelRawValue: 99)
            Issue.record("Expected an unknown raw value error for WorkspaceSessionKernel.FocusClearAction")
        } catch let error as WorkspaceSessionKernel.WorkspaceSessionKernelError {
            #expect(
                error == .unknownRawValue(label: "WorkspaceSessionKernel.FocusClearAction", value: 99)
            )
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
