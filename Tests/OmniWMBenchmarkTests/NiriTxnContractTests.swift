import Foundation
import XCTest

@MainActor
final class NiriTxnContractTests: XCTestCase {
    private let legacySymbols = [
        "omni_niri_ctx_apply_navigation",
        "omni_niri_ctx_apply_mutation",
        "omni_niri_ctx_apply_workspace",
        "omni_niri_ctx_export_runtime_state",
        "NiriStateZigRuntimeProjector",
    ]

    private func repoRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func niriSourceDirURL() -> URL {
        repoRootURL().appendingPathComponent("Sources/OmniWM/Core/Layout/Niri")
    }

    private func zigLayoutContextURL() -> URL {
        repoRootURL()
            .appendingPathComponent("zig")
            .appendingPathComponent("omni")
            .appendingPathComponent("layout_context.zig")
    }

    private func niriSwiftFiles() throws -> [URL] {
        let fileManager = FileManager.default
        let baseURL = niriSourceDirURL()
        guard let enumerator = fileManager.enumerator(
            at: baseURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "swift" else { continue }
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                files.append(fileURL)
            }
        }
        return files
    }

    func testLegacyPerOpRuntimeSymbolsAreNotUsedInSwiftNiriPath() throws {
        let runtimeProjectorPath = niriSourceDirURL().appendingPathComponent("NiriStateZigRuntimeProjector.swift").path
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: runtimeProjectorPath),
            "Legacy runtime projector file should not exist after txn+delta cutover."
        )

        for fileURL in try niriSwiftFiles() {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            for legacySymbol in legacySymbols where content.contains(legacySymbol) {
                XCTFail("Found legacy symbol '\(legacySymbol)' in \(fileURL.path)")
            }
        }
    }

    func testTxnDeltaSymbolsAreUsedBySwiftKernel() throws {
        let kernelURL = niriSourceDirURL().appendingPathComponent("NiriStateZigKernel.swift")
        let kernelContent = try String(contentsOf: kernelURL, encoding: .utf8)

        XCTAssertTrue(kernelContent.contains("omni_niri_ctx_apply_txn"))
        XCTAssertTrue(kernelContent.contains("omni_niri_ctx_export_delta"))
    }

    func testTxnDispatcherHasNoLegacyBridgeMarkersInZig() throws {
        let zigContent = try String(contentsOf: zigLayoutContextURL(), encoding: .utf8)

        XCTAssertFalse(zigContent.contains("legacy_request"))
        XCTAssertFalse(zigContent.contains("legacy_result"))
        XCTAssertFalse(zigContent.contains("buildNavigationApplyRequestFromTxn"))
        XCTAssertFalse(zigContent.contains("buildMutationApplyRequestFromTxn"))
        XCTAssertFalse(zigContent.contains("buildWorkspaceApplyRequestFromTxn"))
        XCTAssertFalse(zigContent.contains("omni_niri_ctx_apply_navigation_impl"))
        XCTAssertFalse(zigContent.contains("omni_niri_ctx_apply_mutation_impl"))
        XCTAssertFalse(zigContent.contains("omni_niri_ctx_apply_workspace_impl"))
    }
}
