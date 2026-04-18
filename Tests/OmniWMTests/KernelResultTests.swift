import COmniWMKernels
@testable import OmniWM
import Testing

@MainActor
struct KernelResultTests {
    @Test func `status mapping keeps known kernel statuses typed`() {
        #expect(KernelError.fromStatus(Int32(OMNIWM_KERNELS_STATUS_OK), operation: "test") == nil)
        #expect(
            KernelError.fromStatus(
                Int32(OMNIWM_KERNELS_STATUS_INVALID_ARGUMENT),
                operation: "test"
            ) == .invalidArgument("test")
        )
        #expect(
            KernelError.fromStatus(
                Int32(OMNIWM_KERNELS_STATUS_ALLOCATION_FAILED),
                operation: "test"
            ) == .allocationFailed
        )
        #expect(
            KernelError.fromStatus(
                Int32(OMNIWM_KERNELS_STATUS_BUFFER_TOO_SMALL),
                operation: "test"
            ) == .bufferTooSmall
        )
    }

    @Test func `logged failure emits the formatted message`() {
        var reportedMessages: [String] = []

        let value: Int? = KernelResult<Int>
            .failure(.unexpectedStatus(code: 99))
            .logged(
                operation: "WindowDecisionKernel.solve",
                component: "WindowDecisionKernel",
                report: { reportedMessages.append($0) }
            )

        let expectedMessage =
            "[WindowDecisionKernel] WindowDecisionKernel.solve failed: Kernel returned unexpected status 99"
        #expect(value == nil)
        #expect(reportedMessages == [expectedMessage])
    }

    @Test func `logged success leaves custom reporter untouched`() {
        var reportedMessages: [String] = []

        let value: Int? = KernelResult<Int>
            .success(42)
            .logged(
                operation: "WindowDecisionKernel.solve",
                component: "WindowDecisionKernel",
                report: { reportedMessages.append($0) }
            )

        #expect(value == 42)
        #expect(reportedMessages.isEmpty)
    }
}
