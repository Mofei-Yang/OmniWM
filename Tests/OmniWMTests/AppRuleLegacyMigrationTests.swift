import Foundation
import Testing

@testable import OmniWM

@Suite struct AppRuleLegacyMigrationTests {
    private func decode(_ json: String) throws -> AppRule {
        let data = try #require(json.data(using: .utf8))
        return try JSONDecoder().decode(AppRule.self, from: data)
    }

    @Test func legacyManageOffAloneMapsToFloat() throws {
        let json = #"""
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "bundleId": "com.example.legacy",
            "manage": "off"
        }
        """#

        let rule = try decode(json)

        #expect(rule.manage == nil)
        #expect(rule.layout == .float)
    }

    @Test func legacyManageOffWithExplicitTileLayoutPreservesTile() throws {
        // When both keys are present, the explicit tracked-window layout wins
        // over the implicit float synthesized from legacy `manage = "off"`.
        let json = #"""
        {
            "id": "22222222-2222-2222-2222-222222222222",
            "bundleId": "com.example.legacy",
            "manage": "off",
            "layout": "tile"
        }
        """#

        let rule = try decode(json)

        #expect(rule.manage == nil)
        #expect(rule.layout == .tile)
    }

    @Test func legacyManageOffWithExplicitAutoLayoutPreservesAuto() throws {
        let json = #"""
        {
            "id": "33333333-3333-3333-3333-333333333333",
            "bundleId": "com.example.legacy",
            "manage": "off",
            "layout": "auto"
        }
        """#

        let rule = try decode(json)

        #expect(rule.manage == nil)
        #expect(rule.layout == .auto)
    }
}
