import CoreGraphics
import Foundation

struct PersistedRestoreIntent: Codable, Equatable {
    let workspaceName: String
    let topologyProfile: TopologyProfile
    let preferredMonitor: DisplayFingerprint?
    let floatingFrame: CGRect?
    let normalizedFloatingOrigin: CGPoint?
    let restoreToFloating: Bool
    let rescueEligible: Bool
}

struct PersistedWindowRestoreBaseKey: Codable, Equatable, Hashable {
    let bundleId: String
    let role: String?
    let subrole: String?
    let windowLevel: Int32?
    let parentWindowId: UInt32?

    init?(
        bundleId: String?,
        role: String?,
        subrole: String?,
        windowLevel: Int32?,
        parentWindowId: UInt32?
    ) {
        guard let normalizedBundleId = Self.normalizeBundleId(bundleId) else {
            return nil
        }

        self.bundleId = normalizedBundleId
        self.role = Self.normalizeText(role)
        self.subrole = Self.normalizeText(subrole)
        self.windowLevel = windowLevel
        self.parentWindowId = parentWindowId
    }

    init?(metadata: ManagedReplacementMetadata) {
        self.init(
            bundleId: metadata.bundleId,
            role: metadata.role,
            subrole: metadata.subrole,
            windowLevel: metadata.windowLevel,
            parentWindowId: metadata.parentWindowId
        )
    }

    private static func normalizeBundleId(_ bundleId: String?) -> String? {
        guard let bundleId = normalizeText(bundleId) else {
            return nil
        }
        return bundleId.lowercased()
    }

}

private extension PersistedWindowRestoreBaseKey {
    static func normalizeText(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else {
            return nil
        }
        return text
    }
}

struct PersistedWindowRestoreKey: Codable, Equatable, Hashable {
    let baseKey: PersistedWindowRestoreBaseKey
    let title: String?

    init?(metadata: ManagedReplacementMetadata, title: String? = nil) {
        guard let baseKey = PersistedWindowRestoreBaseKey(metadata: metadata) else {
            return nil
        }

        self.baseKey = baseKey
        self.title = Self.normalizeTitle(title ?? metadata.title)
    }

    func matches(_ metadata: ManagedReplacementMetadata) -> Bool {
        guard let otherBaseKey = PersistedWindowRestoreBaseKey(metadata: metadata),
              otherBaseKey == baseKey
        else {
            return false
        }

        guard let title else {
            return true
        }
        return title == Self.normalizeTitle(metadata.title)
    }

    static func normalizeTitle(_ title: String?) -> String? {
        PersistedWindowRestoreBaseKey.normalizeText(title)
    }
}

struct PersistedWindowRestoreEntry: Codable, Equatable {
    let key: PersistedWindowRestoreKey
    let restoreIntent: PersistedRestoreIntent
}

struct PersistedWindowRestoreCatalog: Codable, Equatable {
    var entries: [PersistedWindowRestoreEntry]

    static let empty = PersistedWindowRestoreCatalog(entries: [])
}
