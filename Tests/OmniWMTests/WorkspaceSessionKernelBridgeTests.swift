import COmniWMKernels
@testable import OmniWM
import Testing

struct WorkspaceSessionKernelBridgeTests {
    @Test func `validation rejects non OK status`() {
        let failureReason = workspaceSessionKernelOutputValidationFailureReason(
            status: Int32(OMNIWM_KERNELS_STATUS_INVALID_ARGUMENT),
            rawOutput: omniwm_workspace_session_output(),
            monitorCapacity: 0,
            workspaceProjectionCapacity: 0,
            disconnectedCacheCapacity: 0
        )

        #expect(failureReason == "omniwm_workspace_session_plan returned \(OMNIWM_KERNELS_STATUS_INVALID_ARGUMENT)")
    }

    @Test func `validation rejects monitor count overflow`() {
        var output = omniwm_workspace_session_output()
        output.monitor_result_count = 2

        let failureReason = workspaceSessionKernelOutputValidationFailureReason(
            status: Int32(OMNIWM_KERNELS_STATUS_OK),
            rawOutput: output,
            monitorCapacity: 1,
            workspaceProjectionCapacity: 0,
            disconnectedCacheCapacity: 0
        )

        #expect(failureReason == "omniwm_workspace_session_plan reported 2 monitor results for capacity 1")
    }

    @Test func `validation rejects workspace projection count overflow`() {
        var output = omniwm_workspace_session_output()
        output.workspace_projection_count = 3

        let failureReason = workspaceSessionKernelOutputValidationFailureReason(
            status: Int32(OMNIWM_KERNELS_STATUS_OK),
            rawOutput: output,
            monitorCapacity: 0,
            workspaceProjectionCapacity: 2,
            disconnectedCacheCapacity: 0
        )

        #expect(failureReason == "omniwm_workspace_session_plan reported 3 workspace projections for capacity 2")
    }

    @Test func `validation rejects disconnected cache count overflow`() {
        var output = omniwm_workspace_session_output()
        output.disconnected_cache_result_count = 4

        let failureReason = workspaceSessionKernelOutputValidationFailureReason(
            status: Int32(OMNIWM_KERNELS_STATUS_OK),
            rawOutput: output,
            monitorCapacity: 0,
            workspaceProjectionCapacity: 0,
            disconnectedCacheCapacity: 3
        )

        #expect(failureReason == "omniwm_workspace_session_plan reported 4 disconnected cache results for capacity 3")
    }

    @Test func `kernel error carries reason`() {
        let error = WorkspaceSessionKernelError.invocationFailed(
            reason: "omniwm_workspace_session_plan returned 7"
        )

        #expect(error.reason == "omniwm_workspace_session_plan returned 7")
    }

    @Test func `kernel error is equatable`() {
        let a = WorkspaceSessionKernelError.invocationFailed(reason: "x")
        let b = WorkspaceSessionKernelError.invocationFailed(reason: "x")
        let c = WorkspaceSessionKernelError.invocationFailed(reason: "y")

        #expect(a == b)
        #expect(a != c)
    }
}
