import Foundation

@MainActor
final class RestoreState {
    let restorePlanner = RestorePlanner()
    let bootPersistedWindowRestoreCatalog: PersistedWindowRestoreCatalog

    var nativeFullscreenRecordsByOriginalToken: [WindowToken: NativeFullscreenState.Record] = [:]
    var nativeFullscreenOriginalTokenByCurrentToken: [WindowToken: WindowToken] = [:]
    var consumedBootPersistedWindowRestoreKeys: Set<PersistedWindowRestoreKey> = []
    var persistedWindowRestoreCatalogDirty = false
    var persistedWindowRestoreCatalogSaveScheduled = false

    init(settings: SettingsStore) {
        bootPersistedWindowRestoreCatalog = settings.loadPersistedWindowRestoreCatalog()
    }

    func nativeFullscreenOriginalToken(for token: WindowToken) -> WindowToken? {
        if nativeFullscreenRecordsByOriginalToken[token] != nil {
            return token
        }
        return nativeFullscreenOriginalTokenByCurrentToken[token]
    }

    func upsertNativeFullscreenRecord(_ record: NativeFullscreenState.Record) {
        if let previous = nativeFullscreenRecordsByOriginalToken[record.originalToken] {
            nativeFullscreenOriginalTokenByCurrentToken.removeValue(forKey: previous.currentToken)
        }
        nativeFullscreenRecordsByOriginalToken[record.originalToken] = record
        nativeFullscreenOriginalTokenByCurrentToken[record.currentToken] = record.originalToken
    }

    @discardableResult
    func removeNativeFullscreenRecord(
        originalToken: WindowToken
    ) -> NativeFullscreenState.Record? {
        guard let record = nativeFullscreenRecordsByOriginalToken.removeValue(forKey: originalToken) else {
            return nil
        }
        nativeFullscreenOriginalTokenByCurrentToken.removeValue(forKey: record.currentToken)
        return record
    }

    @discardableResult
    func removeNativeFullscreenRecord(
        containing token: WindowToken
    ) -> NativeFullscreenState.Record? {
        guard let originalToken = nativeFullscreenOriginalToken(for: token) else {
            return nil
        }
        return removeNativeFullscreenRecord(originalToken: originalToken)
    }
}
