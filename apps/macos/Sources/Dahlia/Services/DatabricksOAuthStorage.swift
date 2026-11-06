import DahliaRuntimeSupport
import Foundation
import GRDB
import Synchronization

struct DatabricksOAuthCredential: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expirationDate: Date
    let tokenEndpoint: URL
}

struct DatabricksOAuthStorage: Sendable {
    /// Connected workspaces, oldest first.
    var loadConnections: @Sendable () throws -> [DatabricksConnection]
    var saveConnections: @Sendable ([DatabricksConnection]) throws -> Void
    var loadCredential: @Sendable (UUID) throws -> DatabricksOAuthCredential?
    var saveCredential: @Sendable (UUID, DatabricksOAuthCredential) throws -> Void
    var deleteCredential: @Sendable (UUID) throws -> Void

    /// Every storage of one database shares this, so the MainActor views that read it (Calendar's proxy) and each
    /// token request skip SQLite. Only `saveConnections` writes Databricks rows; each save bumps `generation`, so a
    /// read that overlapped a save never stores its older list.
    private struct ConnectionCache {
        var queue: DatabaseQueue?
        var connections: [DatabricksConnection]?
        var generation = 0
    }

    private static let cache = Mutex(ConnectionCache())

    /// Connections live in the app database's `accounts` table, which the app sets once it opens; credentials stay
    /// in the Keychain under the profile.
    static func local(
        profile: DahliaRuntimeProfile = DahliaApplicationSupport.profile(),
        database: @escaping @Sendable () -> DatabaseQueue? = AccountsDatabase.current
    ) -> Self {
        let prefix = "databricksOAuth.\(profile.rawValue)"
        return Self(
            loadConnections: {
                guard let dbQueue = database() else { return [] }
                let (cached, generation) = cache.withLock { ($0.queue === dbQueue ? $0.connections : nil, $0.generation) }
                if let cached { return cached }
                let connections = try dbQueue.read { db in
                    try DahliaAccountConnectionRecord.databricksWorkspaces
                        .order(Column("createdAt"), Column("id"))
                        .fetchAll(db)
                        .map(DatabricksConnection.init)
                }
                cache.withLock {
                    if $0.generation == generation { $0 = ConnectionCache(queue: dbQueue, connections: connections, generation: generation) }
                }
                return connections
            },
            saveConnections: { connections in
                guard let dbQueue = database() else { throw DahliaCloudError.credentialStorageFailed }
                try dbQueue.write { db in
                    let kept = connections.map(\.id)
                    try DahliaAccountConnectionRecord.databricksWorkspaces.filter(!kept.contains(Column("id"))).deleteAll(db)
                    for connection in connections {
                        let createdAt = try DahliaAccountConnectionRecord.fetchOne(db, key: connection.id)?.createdAt ?? .now
                        try DahliaAccountConnectionRecord(connection, createdAt: createdAt).save(db)
                    }
                }
                cache.withLock { $0 = ConnectionCache(generation: $0.generation + 1) }
            },
            loadCredential: { id in
                guard let value = KeychainService.load(key: prefix + "." + id.uuidString) else { return nil }
                return try JSONDecoder().decode(DatabricksOAuthCredential.self, from: Data(value.utf8))
            },
            saveCredential: { id, credential in
                let data = try JSONEncoder().encode(credential)
                try KeychainService.save(key: prefix + "." + id.uuidString, value: String(decoding: data, as: UTF8.self))
            },
            deleteCredential: { id in
                try KeychainService.deleteOrThrow(key: prefix + "." + id.uuidString)
            }
        )
    }
}

extension DatabricksOAuthStorage {
    /// Releases up to 0.29 kept one connection in app defaults. It is not carried over (the user signs in again), so its
    /// keys and Keychain credential are removed once.
    static func removeLegacyConnections(
        profile: DahliaRuntimeProfile = DahliaApplicationSupport.profile(),
        defaults: UserDefaults = .standard,
        deleteCredential: (String) -> Void = { try? KeychainService.deleteOrThrow(key: $0) }
    ) {
        let prefix = "databricksOAuth.\(profile.rawValue)"
        var legacy: [DatabricksConnection] = []
        if let data = defaults.data(forKey: prefix + ".connection"),
           let connection = try? JSONDecoder().decode(DatabricksConnection.self, from: data) {
            legacy.append(connection)
        }
        if let data = defaults.data(forKey: prefix + ".connections"),
           let connections = try? JSONDecoder().decode([DatabricksConnection].self, from: data) {
            legacy += connections
        }
        for connection in legacy {
            deleteCredential(prefix + "." + connection.id.uuidString)
        }
        defaults.removeObject(forKey: prefix + ".connection")
        defaults.removeObject(forKey: prefix + ".connections")
    }
}

/// The app database for code that reads accounts synchronously (Databricks storage). Set once at startup.
enum AccountsDatabase {
    private static let queue = Mutex<DatabaseQueue?>(nil)

    static func configure(_ dbQueue: DatabaseQueue) {
        queue.withLock { $0 = dbQueue }
    }

    @Sendable static func current() -> DatabaseQueue? {
        queue.withLock { $0 }
    }
}

extension DatabricksConnection {
    init(_ record: DahliaAccountConnectionRecord) {
        self.init(id: record.id, host: record.origin, email: record.email, workspaceID: record.workspaceID)
    }
}

extension DahliaAccountConnectionRecord {
    init(_ connection: DatabricksConnection, createdAt: Date) {
        self.init(
            id: connection.id,
            origin: connection.host,
            clientID: DatabricksOAuthService.clientID,
            createdAt: createdAt,
            kind: Self.databricksKind,
            email: connection.email,
            workspaceID: connection.workspaceID
        )
    }
}
