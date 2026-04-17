import Foundation

enum WindowRuleManageAction: String, Codable, CaseIterable, Identifiable {
    case auto

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: "Automatic"
        }
    }
}

enum WindowRuleLayoutAction: String, Codable, CaseIterable, Identifiable {
    case auto
    case tile
    case float

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: "Automatic"
        case .tile: "Tile"
        case .float: "Float"
        }
    }
}

struct AppRule: Codable, Identifiable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case id
        case bundleId
        case appNameSubstring
        case titleSubstring
        case titleRegex
        case axRole
        case axSubrole
        case manage
        case layout
        case assignToWorkspace
        case minWidth
        case minHeight
    }

    let id: UUID
    var bundleId: String
    var appNameSubstring: String?
    var titleSubstring: String?
    var titleRegex: String?
    var axRole: String?
    var axSubrole: String?
    var manage: WindowRuleManageAction?
    var layout: WindowRuleLayoutAction?
    var assignToWorkspace: String?
    var minWidth: Double?
    var minHeight: Double?

    init(
        id: UUID = UUID(),
        bundleId: String,
        appNameSubstring: String? = nil,
        titleSubstring: String? = nil,
        titleRegex: String? = nil,
        axRole: String? = nil,
        axSubrole: String? = nil,
        manage: WindowRuleManageAction? = nil,
        layout: WindowRuleLayoutAction? = nil,
        assignToWorkspace: String? = nil,
        minWidth: Double? = nil,
        minHeight: Double? = nil
    ) {
        self.id = id
        self.bundleId = bundleId
        self.appNameSubstring = appNameSubstring
        self.titleSubstring = titleSubstring
        self.titleRegex = titleRegex
        self.axRole = axRole
        self.axSubrole = axSubrole
        self.manage = manage
        self.layout = layout
        self.assignToWorkspace = assignToWorkspace
        self.minWidth = minWidth
        self.minHeight = minHeight
    }

    var effectiveManageAction: WindowRuleManageAction {
        manage ?? .auto
    }

    var effectiveLayoutAction: WindowRuleLayoutAction {
        layout ?? .auto
    }

    var hasAdvancedMatchers: Bool {
        appNameSubstring?.isEmpty == false ||
            titleSubstring?.isEmpty == false ||
            titleRegex?.isEmpty == false ||
            axRole?.isEmpty == false ||
            axSubrole?.isEmpty == false
    }

    var specificity: Int {
        var score = 1
        if appNameSubstring?.isEmpty == false { score += 1 }
        if titleSubstring?.isEmpty == false { score += 1 }
        if titleRegex?.isEmpty == false { score += 1 }
        if axRole?.isEmpty == false { score += 1 }
        if axSubrole?.isEmpty == false { score += 1 }
        return score
    }

    var hasAnyRule: Bool {
        effectiveManageAction != .auto || effectiveLayoutAction != .auto ||
            assignToWorkspace != nil ||
            minWidth != nil || minHeight != nil ||
            hasAdvancedMatchers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        bundleId = try container.decode(String.self, forKey: .bundleId)
        appNameSubstring = try container.decodeIfPresent(String.self, forKey: .appNameSubstring)
        titleSubstring = try container.decodeIfPresent(String.self, forKey: .titleSubstring)
        titleRegex = try container.decodeIfPresent(String.self, forKey: .titleRegex)
        axRole = try container.decodeIfPresent(String.self, forKey: .axRole)
        axSubrole = try container.decodeIfPresent(String.self, forKey: .axSubrole)

        var decodedLayout = try container.decodeIfPresent(WindowRuleLayoutAction.self, forKey: .layout)
        let rawManage = try container.decodeIfPresent(String.self, forKey: .manage)
        if rawManage == "off" {
            // Accept legacy `manage = "off"` input by normalizing it into the
            // tracked-window model: keep any explicit layout, otherwise
            // synthesize `.float`.
            manage = nil
            if decodedLayout == nil { decodedLayout = .float }
        } else if let rawManage {
            guard let parsed = WindowRuleManageAction(rawValue: rawManage) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .manage,
                    in: container,
                    debugDescription: "Unknown manage action: \(rawManage)"
                )
            }
            manage = parsed
        } else {
            manage = nil
        }
        layout = decodedLayout

        assignToWorkspace = try container.decodeIfPresent(String.self, forKey: .assignToWorkspace)
        minWidth = try container.decodeIfPresent(Double.self, forKey: .minWidth)
        minHeight = try container.decodeIfPresent(Double.self, forKey: .minHeight)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(bundleId, forKey: .bundleId)
        try container.encodeIfPresent(appNameSubstring, forKey: .appNameSubstring)
        try container.encodeIfPresent(titleSubstring, forKey: .titleSubstring)
        try container.encodeIfPresent(titleRegex, forKey: .titleRegex)
        try container.encodeIfPresent(axRole, forKey: .axRole)
        try container.encodeIfPresent(axSubrole, forKey: .axSubrole)
        try container.encodeIfPresent(manage, forKey: .manage)
        try container.encodeIfPresent(layout, forKey: .layout)
        try container.encodeIfPresent(assignToWorkspace, forKey: .assignToWorkspace)
        try container.encodeIfPresent(minWidth, forKey: .minWidth)
        try container.encodeIfPresent(minHeight, forKey: .minHeight)
    }
}
