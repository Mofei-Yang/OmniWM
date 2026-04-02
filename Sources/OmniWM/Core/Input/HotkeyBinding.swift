import Carbon
import Foundation

struct KeyBinding: Equatable, Hashable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let unassigned = KeyBinding(keyCode: UInt32.max, modifiers: 0)

    var isUnassigned: Bool {
        keyCode == UInt32.max && modifiers == 0
    }

    var displayString: String {
        if isUnassigned {
            return "Unassigned"
        }
        return KeySymbolMapper.displayString(keyCode: keyCode, modifiers: modifiers)
    }

    var humanReadableString: String {
        if isUnassigned {
            return "Unassigned"
        }
        return KeySymbolMapper.humanReadableString(keyCode: keyCode, modifiers: modifiers)
    }

    func conflicts(with other: KeyBinding) -> Bool {
        guard !isUnassigned, !other.isUnassigned else { return false }
        return keyCode == other.keyCode && modifiers == other.modifiers
    }
}

extension KeyBinding: Codable {
    private enum CodingKeys: String, CodingKey {
        case keyCode, modifiers
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let string = try? container.decode(String.self),
           let binding = KeySymbolMapper.fromHumanReadable(string) {
            self = binding
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try container.decode(UInt32.self, forKey: .keyCode)
        modifiers = try container.decode(UInt32.self, forKey: .modifiers)
    }

    func encode(to encoder: Encoder) throws {
        if isUnassigned || KeySymbolMapper.keyName(keyCode) != "?" {
            var container = encoder.singleValueContainer()
            try container.encode(humanReadableString)
        } else {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(keyCode, forKey: .keyCode)
            try container.encode(modifiers, forKey: .modifiers)
        }
    }
}

struct HotkeyBinding: Codable, Equatable, Identifiable {
    let id: String
    let command: HotkeyCommand
    var bindings: [KeyBinding]

    var binding: KeyBinding {
        get { bindings.first ?? .unassigned }
        set { bindings = HotkeyBindingRegistry.canonicalizeBindings([newValue]) }
    }

    var primaryBinding: KeyBinding {
        bindings.first ?? .unassigned
    }

    var category: HotkeyCategory {
        ActionCatalog.category(for: id) ?? .focus
    }

    init(id: String, command: HotkeyCommand, bindings: [KeyBinding]) {
        self.id = id
        self.command = command
        self.bindings = HotkeyBindingRegistry.canonicalizeBindings(bindings)
    }

    init(id: String, command: HotkeyCommand, binding: KeyBinding) {
        self.init(id: id, command: command, bindings: [binding])
    }
}

extension HotkeyBinding {
    private enum CodingKeys: String, CodingKey {
        case id, bindings, binding
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        let bindings = try container.decodeIfPresent([KeyBinding].self, forKey: .bindings)
            ?? container.decodeIfPresent(KeyBinding.self, forKey: .binding).map { [$0] }
            ?? []
        guard let command = HotkeyBindingRegistry.command(for: id) else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "Unknown hotkey binding id: \(id)"
            )
        }
        self = HotkeyBinding(id: id, command: command, bindings: bindings)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(bindings, forKey: .bindings)
    }
}

struct PersistedHotkeyBinding: Codable, Equatable {
    let id: String
    let bindings: [KeyBinding]

    private enum CodingKeys: String, CodingKey {
        case id, bindings, binding
    }

    init(id: String, bindings: [KeyBinding]) {
        self.id = id
        self.bindings = HotkeyBindingRegistry.canonicalizeBindings(bindings)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        bindings = try container.decodeIfPresent([KeyBinding].self, forKey: .bindings)
            ?? container.decodeIfPresent(KeyBinding.self, forKey: .binding).map { [$0] }
            ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(bindings, forKey: .bindings)
    }
}

enum HotkeyBindingRegistry {
    private static let commandPaletteID = "openCommandPalette"
    private static let legacyCommandPaletteIDs = (
        windowFinder: "openWindowFinder",
        menuPalette: "openMenuPalette"
    )
    private static let defaultBindings = DefaultHotkeyBindings.all()
    private static let bindingsByID = Dictionary(
        defaultBindings.map { ($0.id, $0) },
        uniquingKeysWith: { first, _ in first }
    )

    static func defaults() -> [HotkeyBinding] {
        defaultBindings
    }

    static func command(for id: String) -> HotkeyCommand? {
        bindingsByID[id]?.command
    }

    static func makeBinding(id: String, binding: KeyBinding) -> HotkeyBinding? {
        guard let defaultBinding = bindingsByID[id] else { return nil }
        return HotkeyBinding(id: id, command: defaultBinding.command, bindings: [binding])
    }

    static func canonicalize(_ persisted: [PersistedHotkeyBinding]) -> [HotkeyBinding] {
        var overrides: [String: [KeyBinding]] = [:]
        var explicitOverrideIDs: Set<String> = []
        var commandPaletteOverridePresent = false
        var legacyWindowFinderBindings: [KeyBinding] = []
        var legacyMenuPaletteBindings: [KeyBinding] = []

        for entry in persisted {
            let normalizedBindings = canonicalizeBindings(entry.bindings)

            switch entry.id {
            case commandPaletteID:
                commandPaletteOverridePresent = true
                explicitOverrideIDs.insert(commandPaletteID)
                overrides[commandPaletteID] = mergeBindings(
                    overrides[commandPaletteID],
                    with: normalizedBindings
                )
            case legacyCommandPaletteIDs.windowFinder:
                legacyWindowFinderBindings = mergeBindings(
                    legacyWindowFinderBindings,
                    with: normalizedBindings
                )
            case legacyCommandPaletteIDs.menuPalette:
                legacyMenuPaletteBindings = mergeBindings(
                    legacyMenuPaletteBindings,
                    with: normalizedBindings
                )
            default:
                guard bindingsByID[entry.id] != nil else { continue }
                explicitOverrideIDs.insert(entry.id)
                overrides[entry.id] = mergeBindings(overrides[entry.id], with: normalizedBindings)
            }
        }

        if !commandPaletteOverridePresent, !legacyWindowFinderBindings.isEmpty || !legacyMenuPaletteBindings.isEmpty {
            explicitOverrideIDs.insert(commandPaletteID)
            overrides[commandPaletteID] = canonicalizeBindings(legacyWindowFinderBindings + legacyMenuPaletteBindings)
        }

        return defaultBindings.map { binding in
            guard explicitOverrideIDs.contains(binding.id) else { return binding }
            let override = overrides[binding.id] ?? []
            return HotkeyBinding(id: binding.id, command: binding.command, bindings: override)
        }
    }

    static func canonicalizeBindings(_ bindings: [KeyBinding]) -> [KeyBinding] {
        var seen: Set<KeyBinding> = []
        return bindings.compactMap { binding in
            guard !binding.isUnassigned, seen.insert(binding).inserted else { return nil }
            return binding
        }
    }

    static func decodePersistedBindings(from data: Data) -> [HotkeyBinding]? {
        guard let rawArray = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return nil
        }

        let decoder = JSONDecoder()
        var persisted: [PersistedHotkeyBinding] = []
        for rawEntry in rawArray {
            guard JSONSerialization.isValidJSONObject(rawEntry),
                  let entryData = try? JSONSerialization.data(withJSONObject: rawEntry),
                  let entry = try? decoder.decode(PersistedHotkeyBinding.self, from: entryData)
            else {
                continue
            }
            persisted.append(entry)
        }

        return canonicalize(persisted)
    }

    static func canonicalizedJSONArray(from rawArray: Any) -> Any {
        guard let entries = rawArray as? [Any] else {
            return encodedJSONArray(for: defaultBindings)
        }

        let decoder = JSONDecoder()
        var persisted: [PersistedHotkeyBinding] = []
        for rawEntry in entries {
            guard JSONSerialization.isValidJSONObject(rawEntry),
                  let entryData = try? JSONSerialization.data(withJSONObject: rawEntry),
                  let entry = try? decoder.decode(PersistedHotkeyBinding.self, from: entryData)
            else {
                continue
            }
            persisted.append(entry)
        }

        return encodedJSONArray(for: canonicalize(persisted))
    }

    private static func encodedJSONArray(for bindings: [HotkeyBinding]) -> Any {
        guard let data = try? JSONEncoder().encode(bindings),
              let json = try? JSONSerialization.jsonObject(with: data)
        else {
            return []
        }
        return json
    }

    private static func mergeBindings(_ current: [KeyBinding]?, with additions: [KeyBinding]) -> [KeyBinding] {
        canonicalizeBindings((current ?? []) + additions)
    }
}

enum HotkeyCategory: String, CaseIterable {
    case workspace = "Workspace"
    case focus = "Focus"
    case move = "Move Window"
    case monitor = "Monitor"
    case layout = "Layout"
    case column = "Column"
}
