import Foundation
import GRDB

/// A provider account (`provider_accounts`): a Dahlia Server, Databricks workspace, or Google identity. The
/// Local Account has no row; its workspaces leave both account columns nil.
struct DahliaAccountConnectionRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    static let databaseTableName = "provider_accounts"
    static let dahliaKind = "dahlia"
    static let databricksKind = "databricks"

    var id: UUID
    var origin: String
    var clientID: String
    var createdAt: Date
    var kind = Self.dahliaKind
    /// The signed-in email and external identity: a Databricks workspace ID or Google subject.
    var email: String?
    var workspaceID: String?
    /// The name the user gave this connection; nil shows its host and email.
    var name: String?
    var settingsJSON = "{}"

    static var dahliaServers: QueryInterfaceRequest<Self> { filter(Column("kind") == dahliaKind) }
    static var databricksWorkspaces: QueryInterfaceRequest<Self> { filter(Column("kind") == databricksKind) }
}
