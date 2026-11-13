import Foundation
import GRDB

/// Account IDs identify this Mac's account records, not a server user or organization.
public enum MCPAccountScope: Equatable, Sendable {
    case local
    case account(UUID)

    public init(argument: String) throws {
        if argument == "local" {
            self = .local
        } else if let id = UUID(uuidString: argument) {
            self = .account(id)
        } else {
            throw Failure.invalidArgument
        }
    }

    func contains(_ row: Row) -> Bool {
        let server: UUID? = row["accountConnectionId"]
        let databricks: UUID? = row["databricksConnectionId"]
        switch self {
        case .local: return server == nil && databricks == nil
        case let .account(id): return server == id || (server == nil && databricks == id)
        }
    }

    func validate(in db: Database) throws {
        if case let .account(id) = self,
           try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM accounts WHERE id = ?)", arguments: [id]) != true {
            throw Failure.accountNotFound
        }
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case invalidArgument
        case accountNotFound
        case conflictingScopes

        public var errorDescription: String? {
            switch self {
            case .invalidArgument: "--account must specify local or a valid account UUID"
            case .accountNotFound: "The configured account was not found on this Mac."
            case .conflictingScopes: "--account and --workspace / --workspace-id are mutually exclusive"
            }
        }
    }
}
