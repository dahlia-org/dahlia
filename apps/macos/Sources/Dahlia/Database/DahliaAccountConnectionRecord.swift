import Foundation
import GRDB

/// A provider account (`provider_accounts`): a Dahlia Server, or a Databricks workspace (`kind = "databricks"`). The
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
    /// The signed-in user and workspace ID of a Databricks account, fetched after sign-in.
    var email: String?
    var workspaceID: String?
    /// The name the user gave this connection; nil shows its host and email.
    var name: String?

    static var dahliaServers: QueryInterfaceRequest<Self> { filter(Column("kind") == dahliaKind) }
    static var databricksWorkspaces: QueryInterfaceRequest<Self> { filter(Column("kind") == databricksKind) }
}
