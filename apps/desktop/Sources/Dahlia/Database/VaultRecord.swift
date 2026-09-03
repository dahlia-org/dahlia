import Foundation
import GRDB

/// 保管庫を表す GRDB レコード。path は保管庫ディレクトリの絶対パスに対応する。
struct VaultRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "vaults"

    var id: UUID
    var path: String
    var name: String
    var createdAt: Date
    var lastOpenedAt: Date
    var accountConnectionId: UUID?
    var localAIProvider: String = AIAccountProvider.chatGPTSubscription.rawValue
    var databricksProfile = ""
    var summaryModelID = "gpt-5.6-luna"
    var summaryReasoningEffort = "high"
    var chatModelID = ""
    var chatReasoningEffort: String = CodexReasoningEffortOption.defaultValue
    var aiSettingsBackfilled = true
    var syncEnabled = false
    var syncConfirmedConnectionId: UUID?
    var syncDeletionMode: String?
    var syncDeletionApproved = false
    var syncDeletionConnectionId: UUID?
    var syncBulkDeleteApproved = false
    var serverRevision: Int?
    var syncCursor: String?
    var syncConflictJSON: String?
    var syncBootstrapPending = false

    var localProvider: AIAccountProvider {
        get { AIAccountProvider(rawValue: localAIProvider) ?? .chatGPTSubscription }
        set { localAIProvider = newValue.rawValue }
    }

    /// 保管庫ディレクトリの URL。
    var url: URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }
}

extension VaultRecord {
    var requiresServerDeletionBeforeRemoval: Bool {
        syncEnabled || syncConfirmedConnectionId != nil || syncDeletionMode != nil
    }
}

struct CloudVaultRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    static let databaseTableName = "cloud_vaults"

    var vaultId: UUID
    var connectionId: UUID
    var name: String
    var createdAt: Date
    var revision: Int

    var id: String { "\(connectionId.uuidString):\(vaultId.uuidString)" }
}
