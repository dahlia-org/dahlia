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
    var syncRole: String?
    var syncConfirmedConnectionId: UUID?
    var syncPullCursor: String?
    var syncLastCommittedCursor: String?

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
        syncEnabled || syncConfirmedConnectionId != nil
    }
}

struct CloudVaultRecord: Identifiable, Equatable, Sendable {
    var vaultId: UUID
    var connectionId: UUID
    var name: String
    var createdAt: Date
    var revision: Int
    var role: String

    var id: String { "\(connectionId.uuidString):\(vaultId.uuidString)" }
}
