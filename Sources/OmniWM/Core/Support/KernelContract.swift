import Foundation

enum KernelContract {
    static func require<T>(
        _ value: T?,
        _ message: @autoclosure () -> String,
        file: StaticString = #fileID,
        line: UInt = #line
    ) -> T {
        guard let value else {
            preconditionFailure("Kernel contract violation: \(message())", file: file, line: line)
        }
        return value
    }

    /// Called from the `default:` branch of a switch on a raw discriminant
    /// emitted by a Zig kernel. Any unknown value is a contract violation:
    /// the Swift Package must never silently coerce an unrecognised kernel
    /// output into a no-op, because that hides stale ABI or new kernel
    /// outputs that were not yet modelled in Swift.
    static func unknownRawValue<RawValue: CustomStringConvertible>(
        _ rawValue: RawValue,
        label: StaticString,
        file: StaticString = #fileID,
        line: UInt = #line
    ) -> Never {
        preconditionFailure(
            "Kernel contract violation: unknown \(label) raw value \(rawValue.description)",
            file: file,
            line: line
        )
    }
}
