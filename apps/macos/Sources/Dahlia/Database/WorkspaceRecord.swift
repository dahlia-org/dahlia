import Foundation
import GRDB

/// ワークスペースを表す GRDB レコード。path は任意のローカル出力ディレクトリに対応する。
/// The table's account and sync columns (`accountConnectionId`, `databricksConnectionId`, `sync…`) are no longer read:
/// no workspace belongs to an account, and each launch clears them (`SingleAccountMigration`).
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

    var localProvider: AIAccountProvider {
        get { AIAccountProvider(rawValue: localAIProvider) ?? .chatGPTSubscription }
        set { localAIProvider = newValue.rawValue }
    }

    /// Markdown などを出力する任意のローカルディレクトリ。
    var url: URL? {
        path.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
}
