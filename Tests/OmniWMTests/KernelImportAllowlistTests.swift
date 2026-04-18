import Foundation
import Testing

/// Enforces the post-M1 architectural invariant that `import COmniWMKernels`
/// only appears in a small, allowlisted set of files. Every move into
/// `Sources/OmniWM/Core/Kernel/` should be paired with an allowlist update
/// in the same commit; every kernel deletion (M3, M6, M8, M10, M11) should
/// remove the corresponding bridge from the allowlist.
struct KernelImportAllowlistTests {
    /// Relative-to-package-root paths of every Swift source file permitted to
    /// `import COmniWMKernels`. Sorted for readability; the comparison uses a
    /// `Set`. Update this list in the same commit that moves a file into or
    /// out of `Sources/OmniWM/Core/Kernel/`.
    static let allowedImports: Set<String> = [
        // Pre-existing bridges, still in their original locations:
        "Sources/OmniWM/Core/Kernel/KernelResult.swift",
        "Sources/OmniWM/Core/Kernel/NiriTopologyKernel.swift",
        "Sources/OmniWM/Core/Kernel/WindowDecisionKernel.swift",
        "Sources/OmniWM/Core/Kernel/WorkspaceNavigationKernel.swift",
        "Sources/OmniWM/Core/Kernel/WorkspaceSessionKernelBridge.swift",
        "Sources/OmniWM/Core/Layout/Dwindle/DwindleLayoutEngine.swift",
        "Sources/OmniWM/Core/Layout/Niri/NiriConstraintSolver.swift",
        "Sources/OmniWM/Core/Layout/Niri/NiriLayout.swift",
        "Sources/OmniWM/Core/Layout/Niri/NiriViewport.swift",
        "Sources/OmniWM/Core/Platform/Display/MonitorRestoreAssignments.swift",
        "Sources/OmniWM/Core/Overview/OverviewLayoutCalculator.swift",
        "Sources/OmniWM/Core/Engine/RestorePlanner.swift",
        "Sources/OmniWMIPC/ZigIPCSupport.swift",
    ]

    @Test
    func kernelImportsAreLimitedToAllowlistedFiles() throws {
        let packageRoot = try Self.locatePackageRoot()
        let sourcesDir = packageRoot.appendingPathComponent("Sources", isDirectory: true)

        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: sourcesDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            Issue.record("Could not enumerate \(sourcesDir.path)")
            return
        }

        var offenders: [String] = []
        var allowlistedButMissing = Self.allowedImports
        let rootPrefix = packageRoot.path + "/"

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "swift" else { continue }
            let contents = try String(contentsOf: fileURL, encoding: .utf8)
            guard Self.fileImportsKernels(contents: contents) else { continue }

            var absolutePath = fileURL.standardizedFileURL.path
            if absolutePath.hasPrefix(rootPrefix) {
                absolutePath.removeFirst(rootPrefix.count)
            }
            let relativePath = absolutePath

            if Self.allowedImports.contains(relativePath) {
                allowlistedButMissing.remove(relativePath)
            } else {
                offenders.append(relativePath)
            }
        }

        #expect(
            offenders.isEmpty,
            """
            Files NOT on the allowlist import COmniWMKernels. Either add the
            file to `KernelImportAllowlistTests.allowedImports` (with a reason
            comment) or move the import into `Sources/OmniWM/Core/Kernel/`.
            Offenders: \(offenders.sorted())
            """
        )

        #expect(
            allowlistedButMissing.isEmpty,
            """
            Files on the allowlist no longer import COmniWMKernels. Remove
            them from `KernelImportAllowlistTests.allowedImports`. Stale
            entries: \(allowlistedButMissing.sorted())
            """
        )
    }

    /// True if the file contents contain a top-level `import COmniWMKernels`
    /// line. Matches the literal declaration to avoid false positives from
    /// comments or string literals that mention the module name.
    private static func fileImportsKernels(contents: String) -> Bool {
        for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "import COmniWMKernels" { return true }
            if trimmed == "@testable import COmniWMKernels" { return true }
        }
        return false
    }

    /// Walks up from this test file's source path until it finds a directory
    /// containing `Package.swift`. That directory is the package root.
    private static func locatePackageRoot(file: StaticString = #filePath) throws -> URL {
        var directory = URL(fileURLWithPath: String(describing: file))
            .standardizedFileURL
            .deletingLastPathComponent()
        let fileManager = FileManager.default
        while !fileManager.fileExists(
            atPath: directory.appendingPathComponent("Package.swift").path
        ) {
            let parent = directory.deletingLastPathComponent()
            if parent == directory {
                throw KernelImportAllowlistError.packageRootNotFound(startingFrom: String(describing: file))
            }
            directory = parent
        }
        return directory
    }
}

private enum KernelImportAllowlistError: Error, CustomStringConvertible {
    case packageRootNotFound(startingFrom: String)

    var description: String {
        switch self {
        case .packageRootNotFound(let path):
            return "Package root (directory containing Package.swift) not found walking up from \(path)"
        }
    }
}
