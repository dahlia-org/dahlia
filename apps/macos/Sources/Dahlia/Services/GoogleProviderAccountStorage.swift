import Foundation
import GRDB

struct GoogleProviderAccountStorage: Sendable {
    var load: @Sendable () throws -> [GoogleProviderAccount]
    var save: @Sendable (GoogleProviderAccount) throws -> Void
    var remove: @Sendable (UUID) throws -> Void

    static func local(database: @escaping @Sendable () -> (any DatabaseWriter)? = AccountsDatabase.current) -> Self {
        Self(
            load: {
                guard let queue = database() else { return [] }
                return try queue.read { db in
                    try DahliaAccountConnectionRecord.filter(Column("kind") == "google")
                        .order(Column("createdAt"), Column("id")).fetchAll(db).map { record in
                            GoogleProviderAccount(
                                id: record.id,
                                account: GoogleCalendarAccount(
                                    id: record.workspaceID ?? "",
                                    displayName: record.email ?? L10n.google,
                                    email: record.email ?? ""
                                ),
                                name: record.name
                            )
                        }
                }
            },
            save: { account in
                guard let queue = database() else { throw DahliaCloudError.credentialStorageFailed }
                try queue.write { db in
                    let previous = try DahliaAccountConnectionRecord.fetchOne(db, key: account.id)
                    try DahliaAccountConnectionRecord(
                        id: account.id, origin: "https://accounts.google.com/#\(account.id.uuidString)",
                        clientID: GoogleCalendarConfiguration.clientID ?? "", createdAt: previous?.createdAt ?? .now,
                        kind: "google", email: account.account.email, workspaceID: account.account.id, name: account.name
                    ).save(db)
                }
            },
            remove: { id in
                guard let queue = database() else { throw DahliaCloudError.credentialStorageFailed }
                try queue.write { db in
                    try DahliaAccountConnectionRecord.filter(Column("kind") == "google").filter(Column("id") == id).deleteAll(db)
                }
            }
        )
    }
}

/// Keeps provider metadata IO off MainActor and orders registration, rename and removal.
actor GoogleProviderAccountWorker {
    private let storage: GoogleProviderAccountStorage
    init(storage: GoogleProviderAccountStorage = .local()) { self.storage = storage }
    func load() throws -> [GoogleProviderAccount] { try storage.load() }
    func save(_ account: GoogleProviderAccount) throws { try storage.save(account) }
    func remove(_ id: UUID) throws { try storage.remove(id) }
}
