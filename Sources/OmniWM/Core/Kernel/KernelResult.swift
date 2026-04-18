import COmniWMKernels
import Foundation

enum KernelResult<Success> {
    case success(Success)
    case failure(KernelError)

    var value: Success? {
        switch self {
        case .success(let value):
            value
        case .failure:
            nil
        }
    }

    var error: KernelError? {
        switch self {
        case .success:
            nil
        case .failure(let error):
            error
        }
    }

    func logged(
        operation: StaticString,
        component: StaticString = "Kernel",
        report: (String) -> Void = defaultKernelFailureReport
    ) -> Success? {
        switch self {
        case .success(let value):
            return value
        case .failure(let error):
            report("[\(String(describing: component))] \(String(describing: operation)) failed: \(error)")
            return nil
        }
    }
}

enum KernelError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidArgument(String)
    case allocationFailed
    case bufferTooSmall
    case abiMismatch(symbol: String)
    case unexpectedStatus(code: Int32)

    var description: String {
        switch self {
        case .invalidArgument(let details):
            return "Kernel reported invalid argument: \(details)"
        case .allocationFailed:
            return "Kernel allocation failed"
        case .bufferTooSmall:
            return "Kernel output buffer was too small"
        case .abiMismatch(let symbol):
            return "Kernel ABI mismatch while decoding \(symbol)"
        case .unexpectedStatus(let code):
            return "Kernel returned unexpected status \(code)"
        }
    }

    static func fromStatus(
        _ status: Int32,
        operation: StaticString
    ) -> KernelError? {
        switch status {
        case Int32(OMNIWM_KERNELS_STATUS_OK):
            nil
        case Int32(OMNIWM_KERNELS_STATUS_INVALID_ARGUMENT):
            .invalidArgument(String(describing: operation))
        case Int32(OMNIWM_KERNELS_STATUS_ALLOCATION_FAILED):
            .allocationFailed
        case Int32(OMNIWM_KERNELS_STATUS_BUFFER_TOO_SMALL):
            .bufferTooSmall
        default:
            .unexpectedStatus(code: status)
        }
    }

    static func abiMismatch(
        label: StaticString,
        rawValue: UInt32
    ) -> KernelError {
        .abiMismatch(symbol: "\(String(describing: label))(\(rawValue))")
    }
}

private func defaultKernelFailureReport(_ message: String) {
    WMLog.error(.kernel, message)
    fputs("\(message)\n", stderr)
#if DEBUG
    assertionFailure(message)
#endif
}
