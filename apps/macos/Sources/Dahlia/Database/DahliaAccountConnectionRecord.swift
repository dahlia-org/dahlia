import Foundation
import GRDB

/// A signed-in account (`accounts`): a Dahlia Server, or a Databricks workspace (`kind = "databricks"`). The Local
/// Account has no row; its workspaces leave both account columns nil.
struct DahliaAccountConnectionRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    static let databaseTableName = "accounts"
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

    static var dahliaServers: QueryInterfaceRequest<Self> { filter(Column("kind") == dahliaKind) }
    static var databricksWorkspaces: QueryInterfaceRequest<Self> { filter(Column("kind") == databricksKind) }
}
