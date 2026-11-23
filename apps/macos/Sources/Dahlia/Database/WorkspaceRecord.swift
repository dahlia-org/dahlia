import Foundation
import GRDB

/// ワークスペースを表す GRDB レコード。path は任意のローカル出力ディレクトリに対応する。
struct WorkspaceRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "workspaces"

    var id: UUID
    var path: String?
    var icon: String?
    var color: String?

    var appearance: ProjectAppearance? {
        get {
            guard icon != nil || color != nil else { return nil }
            return ProjectAppearance(
                icon: icon.flatMap(ProjectIcon.init(rawValue:)) ?? .workspace,
                color: color.flatMap(ProjectThemeColor.init(rawValue:)) ?? .neutral
            )
        }
        set {
            icon = newValue?.icon.rawValue
            color = newValue?.color.rawValue
        }
    }

    var name: String
    var createdAt: Date
    var lastOpenedAt: Date
    /// The Dahlia Server account whose workspace this is. The table's `databricksConnectionId` column is no longer
    /// read: no workspace belongs to a Databricks connection, and each launch clears it (`SingleAccountMigration`).
    var accountConnectionId: UUID?
    var localAIProvider: String = AIAccountProvider.chatGPTSubscription.rawValue
    var databricksProfile = ""
    var generationSettings = WorkspaceGenerationSettings()
    var summaryModelID: String {
        get { generationSettings.local.model }
        set { generationSettings.local.model = newValue }
    }

    var summaryReasoningEffort: String {
        get { generationSettings.local.reasoningEffort }
        set { generationSettings.local.reasoningEffort = newValue }
    }

    var chatModelID = ""
    var chatReasoningEffort: String = CodexReasoningEffortOption.defaultValue
    var aiSettingsBackfilled = true
    var personalUserId: UUID?
    var organizationId: UUID?
    var syncRole: String?
    var syncConfirmedConnectionId: UUID?
    var syncPullCursor: String?
    var syncLastCommittedCursor: String?
    var syncRecoveryState: String?
    var syncPullErrorJSON: String?

    var localProvider: AIAccountProvider {
        get { AIAccountProvider(rawValue: localAIProvider) ?? .chatGPTSubscription }
        set { localAIProvider = newValue.rawValue }
    }

    /// Markdown などを出力する任意のローカルディレクトリ。
    var url: URL? {
        path.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
}

extension WorkspaceRecord {
    /// Whether two workspaces are listed under the same account (the app's, or one Dahlia account).
    func belongsToSameAccount(as other: WorkspaceRecord) -> Bool {
        accountConnectionId == other.accountConnectionId
    }

    mutating func moveToLocalAccount() {
        accountConnectionId = nil
        organizationId = nil
        personalUserId = nil
        syncRole = nil
        syncConfirmedConnectionId = nil
        syncPullCursor = nil
        syncLastCommittedCursor = nil
        syncPullErrorJSON = nil
        generationSettings.processing.location = .local
    }

    var isAwaitingInitialSync: Bool {
        accountConnectionId != nil && syncConfirmedConnectionId == accountConnectionId && syncPullCursor == nil
    }

    var allowsCanonicalEdits: Bool {
        accountConnectionId == nil || syncRole == "admin" || syncRole == "editor"
    }

    var allowsWorkspaceManagement: Bool {
        accountConnectionId == nil || syncRole == "admin"
    }

    var requiresServerDeletionBeforeRemoval: Bool {
        allowsWorkspaceManagement && accountConnectionId != nil
    }
}

struct CloudWorkspaceRecord: Identifiable, Equatable, Sendable {
    var workspaceId: UUID
    var connectionId: UUID
    var organizationId: UUID
    var personalUserId: UUID?
    var icon: String?
    var color: String?
    var name: String
    var createdAt: Date
    var revision: Int
    var role: String

    var generationSettings = WorkspaceGenerationSettings()

    var id: String { "\(connectionId.uuidString):\(workspaceId.uuidString)" }
}
