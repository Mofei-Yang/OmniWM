import Foundation
import PackagePlugin

@main
struct OmniWMKernelsBuildPlugin: BuildToolPlugin {
    func createBuildCommands(
        context: PluginContext,
        target: Target
    ) async throws -> [Command] {
        let scriptURL = context.package.directoryURL.appending(path: "Scripts/build-zig-kernels.sh")
        let outputDirectory = context.pluginWorkDirectoryURL.appending(path: "zig-kernels")
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let home = ProcessInfo.processInfo.environment["HOME"] ?? context.package.directoryURL.path
        let cacheDirectory = outputDirectory.appending(path: "zig-cache")

        return [
            .prebuildCommand(
                displayName: "Build OmniWM Zig kernels for \(target.name)",
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "\"$1\" all && mkdir -p \"$2\" && touch \"$2/kernels-built.txt\"",
                    "omniwm-kernels-plugin",
                    scriptURL.path,
                    outputDirectory.path
                ],
                environment: [
                    "PATH": path,
                    "HOME": home,
                    "XDG_CACHE_HOME": cacheDirectory.path,
                    "ZIG_GLOBAL_CACHE_DIR": cacheDirectory.path,
                    "OMNIWM_ZIG_KERNEL_OUTPUT_ROOT": outputDirectory.path
                ],
                outputFilesDirectory: outputDirectory
            )
        ]
    }
}
