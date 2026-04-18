import Foundation
import Testing

struct PlatformBoundaryAllowlistTests {
    static let allowedSkyLightSharedUsages: Set<String> = [
        "Sources/OmniWM/Core/Platform/WMPlatform.swift",
        "Sources/OmniWM/Core/Platform/WindowServer/CGSEventObserver.swift",
    ]

    static let allowedSilgenNameDeclarations: Set<String> = [
        "Sources/OmniWM/Core/Platform/PrivateAPIFFI.swift",
    ]

    static let allowedWMPlatformSharedUsages: Set<String> = [
        "Sources/OmniWM/Core/Platform/WMPlatform.swift",
    ]

    static let allowedAXWindowFFIUsages: Set<String> = [
        "Sources/OmniWM/Core/Platform/Accessibility/AppAXContext.swift",
        "Sources/OmniWM/Core/Platform/Accessibility/AXWindow.swift",
        "Sources/OmniWM/Core/Platform/PrivateAPIFFI.swift",
    ]

    @Test
    func skylightSingletonUsageIsAllowlisted() throws {
        try assertAllowlistedUsage(
            needle: "SkyLight.shared",
            allowedFiles: Self.allowedSkyLightSharedUsages,
            failurePrefix: "Files outside the platform boundary use `SkyLight.shared`."
        )
    }

    @Test
    func silgenNameDeclarationsStayInsidePlatformBoundary() throws {
        try assertAllowlistedUsage(
            needle: "@_silgen_name",
            allowedFiles: Self.allowedSilgenNameDeclarations,
            failurePrefix: "Files outside the platform boundary declare raw private API symbols."
        )
    }

    @Test
    func wmPlatformSingletonUsageIsAllowlisted() throws {
        try assertAllowlistedUsage(
            needle: "WMPlatform.shared",
            allowedFiles: Self.allowedWMPlatformSharedUsages,
            failurePrefix: "Files outside the platform boundary use `WMPlatform.shared`."
        )
    }

    @Test
    func axWindowFFIUsageIsAllowlisted() throws {
        try assertAllowlistedUsage(
            needle: "_AXUIElementGetWindow",
            allowedFiles: Self.allowedAXWindowFFIUsages,
            failurePrefix: "Files outside the accessibility/platform boundary call `_AXUIElementGetWindow` directly."
        )
    }

    @Test
    func wmPlatformLiveFacadeDoesNotReturn() throws {
        try assertAllowlistedUsage(
            needle: "WMPlatform.live",
            allowedFiles: [],
            failurePrefix: "Legacy `WMPlatform.live` façade usage reappeared."
        )
    }

    private func assertAllowlistedUsage(
        needle: String,
        allowedFiles: Set<String>,
        failurePrefix: String
    ) throws {
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
        var allowlistedButMissing = allowedFiles
        let rootPrefix = packageRoot.path + "/"

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "swift" else { continue }
            let contents = try String(contentsOf: fileURL, encoding: .utf8)
            guard contents.contains(needle) else { continue }

            var absolutePath = fileURL.standardizedFileURL.path
            if absolutePath.hasPrefix(rootPrefix) {
                absolutePath.removeFirst(rootPrefix.count)
            }
            let relativePath = absolutePath

            if allowedFiles.contains(relativePath) {
                allowlistedButMissing.remove(relativePath)
            } else {
                offenders.append(relativePath)
            }
        }

        #expect(
            offenders.isEmpty,
            """
            \(failurePrefix)
            Offenders: \(offenders.sorted())
            """
        )

        #expect(
            allowlistedButMissing.isEmpty,
            """
            Allowlist entries no longer contain `\(needle)`. Remove stale entries.
            Stale entries: \(allowlistedButMissing.sorted())
            """
        )
    }

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
                throw PlatformBoundaryAllowlistError.packageRootNotFound(startingFrom: String(describing: file))
            }
            directory = parent
        }
        return directory
    }
}

private enum PlatformBoundaryAllowlistError: Error, CustomStringConvertible {
    case packageRootNotFound(startingFrom: String)

    var description: String {
        switch self {
        case .packageRootNotFound(let path):
            return "Package root (directory containing Package.swift) not found walking up from \(path)"
        }
    }
}
