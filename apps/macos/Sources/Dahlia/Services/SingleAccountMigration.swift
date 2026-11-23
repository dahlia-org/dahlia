import Foundation
import GRDB

/// Moves this Mac to the app's one account, once. The account keeps the Local Account's key. When the workspace opened
/// last belonged to a Databricks account, that account's history, settings, and agent files move to it, and its
/// Databricks connection stays as a provider account. No workspace belongs to an account afterwards.
///
/// Nothing is deleted: rows are rewritten in place, and the old agent folders and settings keys stay for a release.
/// Files and settings move once; until they have, the next launch copies them again and reaches the same result. The
/// rows move on every launch, which is cheap, so a backup restored from before the move ends the same way.
struct SingleAccountMigration {
    static let completedKey = "singleAccountMigration.completed"
    /// The Databricks connection whose data moves (empty for none), decided once so a later run moves the same one.
    static let sourceKey = "singleAccountMigration.source"
    static let accountKey = AppAccount.key
    static let providerIDsKey = "singleAccountMigration.providerIDs"

    var dbQueue: any DatabaseWriter
    var locator: PiAgentDirectoryLocator
    var defaults: UserDefaults
    var loadSecret: (String) -> String?
    var saveSecret: (String, String) -> Void

    /// Runs off MainActor: it copies files and reads the Keychain.
    @concurrent
    static func runAtLaunch(dbQueue: any DatabaseWriter) async throws {
        try Self(
            dbQueue: dbQueue,
            locator: PiAgentDirectoryLocator(),
            defaults: .standard,
            loadSecret: { KeychainService.load(key: $0) },
            saveSecret: { try? KeychainService.save(key: $0, value: $1) }
        ).run()
    }

    func run() throws {
        let source = try sourceConnectionID()
        if !defaults.bool(forKey: Self.completedKey) {
            try copyAgentFiles(from: source)
            if let source {
                copySettings(from: source)
                copySecrets(from: source)
            }
            // The copied settings name the legacy provider ID again, so it is renamed again.
            defaults.removeObject(forKey: Self.providerIDsKey)
        }
        try dbQueue.write { db in
            if let source { try moveRows(from: source, in: db) }
            try db.execute(sql: "UPDATE workspaces SET databricksConnectionId = NULL WHERE databricksConnectionId IS NOT NULL")
            try Self.moveServerWorkspaces(in: db)
        }
        defaults.set(true, forKey: Self.completedKey)
        try renameLegacyProviderID(source: source)
    }

    /// The Databricks account of the workspace opened last, which is the account this Mac used.
    func sourceConnectionID() throws -> UUID? {
        if let saved = defaults.string(forKey: Self.sourceKey) { return UUID(uuidString: saved) }
        // The column is read here only; the app no longer models it.
        let row = try dbQueue.read { db in
            try Row.fetchOne(db, sql: """
            SELECT accountConnectionId, databricksConnectionId FROM workspaces ORDER BY lastOpenedAt DESC, id LIMIT 1
            """)
        }
        let source: UUID? = (row?["accountConnectionId"] as UUID?) == nil ? row?["databricksConnectionId"] : nil
        defaults.set(source?.uuidString ?? "", forKey: Self.sourceKey)
        return source
    }

    // MARK: Agent files

    /// Copies the Databricks account's agent folder, then fills in what only the Local Account's had: its
    /// subscription sign-ins, its device ID, and sessions and skills the Databricks account lacked.
    private func copyAgentFiles(from source: UUID?) throws {
        let target = locator.sharedAgentURL
        let sources = ([source.map { $0.uuidString.lowercased() }].compactMap(\.self) + [Self.accountKey])
            .map { locator.legacyAgentURL(accountKey: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        try PiAgentDirectoryLocator.createPrivateDirectory(target)
        for directory in sources {
            try merge(directory, into: target)
        }
    }

    /// Copies what `target` lacks. Existing files win, so the first source wins and a run again changes nothing it
    /// already copied. A skill is one unit: a skill already there keeps all of its files.
    private func merge(_ source: URL, into target: URL, isSkills: Bool = false) throws {
        let fileManager = FileManager.default
        for item in try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey]) {
            let destination = target.appending(path: item.lastPathComponent)
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if !fileManager.fileExists(atPath: destination.path) {
                try fileManager.copyItem(at: item, to: destination)
            } else if item.lastPathComponent == "auth.json", !isDirectory {
                try mergeSignIns(item, into: destination)
            } else if isDirectory, !isSkills {
                try merge(item, into: destination, isSkills: item.lastPathComponent == "skills")
            }
        }
    }

    /// Adds the sign-ins the target lacks; each top-level key is one provider's sign-in.
    private func mergeSignIns(_ source: URL, into target: URL) throws {
        guard case let .object(added) = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: source)),
              case var .object(signIns) = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: target))
        else { return }
        let missing = added.filter { signIns[$0.key] == nil }
        guard !missing.isEmpty else { return }
        signIns.merge(missing) { current, _ in current }
        try JSONEncoder().encode(JSONValue.object(signIns)).write(to: target, options: .atomic)
    }

    // MARK: Settings

    /// Copies each per-account setting of the Databricks account to the account's key; the account used it, so its
    /// values win.
    private func copySettings(from source: UUID) {
        let suffix = "." + source.uuidString.lowercased()
        for (key, value) in defaults.dictionaryRepresentation() where key.hasSuffix(suffix) {
            var base = String(key.dropLast(suffix.count))
            // Inference settings name a Databricks account `databricks.<id>`.
            if base == "accountInferenceSettings.databricks" { base = "accountInferenceSettings" }
            defaults.set(value, forKey: base + "." + Self.accountKey)
        }
        // The meeting settings in use belong to the account named here; the Databricks account's become the account's.
        let ownerKey = AppSettings.meetingSettingsAccountUserDefaultsKey
        let owner = defaults.string(forKey: ownerKey)
        if owner != source.uuidString.lowercased(),
           let saved = defaults.dictionary(forKey: AppSettings.meetingSettingsUserDefaultsKey(for: source.uuidString.lowercased())) {
            for key in AppSettings.accountMeetingSettingKeys {
                defaults.set(saved[key], forKey: key)
            }
        }
        if owner != nil { defaults.set(Self.accountKey, forKey: ownerKey) }
    }

    private func copySecrets(from source: UUID) {
        let databricks = source.uuidString.lowercased()
        for variable in PiLaunchSettings.load(accountKey: databricks, defaults: defaults).variables where variable.isSecret {
            guard let value = loadSecret(PiLaunchSettings.secretKey(accountKey: databricks, id: variable.id)) else { continue }
            saveSecret(PiLaunchSettings.secretKey(id: variable.id), value)
        }
    }

    // MARK: Provider IDs

    /// Every saved `databricks` provider ID named the one connection the account used; it becomes that connection's
    /// host, as Pi names every Databricks connection now. Once, after the rows and files moved.
    private func renameLegacyProviderID(source: UUID?) throws {
        guard !defaults.bool(forKey: Self.providerIDsKey) else { return }
        let origin = try dbQueue.read { db in
            try (source.flatMap { try DahliaAccountConnectionRecord.fetchOne(db, key: $0) }
                ?? DahliaAccountConnectionRecord.databricksWorkspaces.order(Column("createdAt"), Column("id")).fetchOne(db))?.origin
        }
        if let host = origin.flatMap(URL.init(string:)).map(AgentMCPProvider.id(for:)) {
            let legacy = PiProviderConfiguration.legacyDatabricksProviderID
            try dbQueue.write { db in
                for (table, column) in try Self.modelColumns(in: db) {
                    let name = column.quotedDatabaseIdentifier
                    // A model reference is the whole value, or a JSON string within the generation settings.
                    try db.execute(
                        sql: """
                        UPDATE \(table.quotedDatabaseIdentifier) SET \(name) = CASE
                            WHEN \(name) LIKE ? THEN ? || substr(\(name), ?)
                            ELSE REPLACE(\(name), ?, ?) END
                        WHERE \(name) LIKE ? OR \(name) LIKE ?
                        """,
                        arguments: [
                            legacy + "/%", host, legacy.count + 1,
                            "\"\(legacy)/", "\"\(host)/",
                            legacy + "/%", "%\"\(legacy)/%",
                        ]
                    )
                }
            }
            for (key, value) in defaults.dictionaryRepresentation() where key.hasSuffix("." + Self.accountKey) {
                // The MCP registrations name the provider by ID alone.
                let renamed = Self.rename(value, from: legacy, to: host, wholeIDs: key.hasPrefix("agentMCPs."))
                if let renamed { defaults.set(renamed, forKey: key) }
            }
            let saved = locator.sharedAgentURL.appending(path: "gateway-models.json")
            if let data = FileManager.default.contents(atPath: saved.path),
               case var .object(services) = try JSONDecoder().decode(JSONValue.self, from: data),
               let listed = services.removeValue(forKey: legacy) {
                services[host] = services[host] ?? listed
                try JSONEncoder().encode(JSONValue.object(services)).write(to: saved, options: .atomic)
            }
        }
        defaults.set(true, forKey: Self.providerIDsKey)
    }

    private static func modelColumns(in db: Database) throws -> [(String, String)] {
        try Row.fetchAll(db, sql: """
        SELECT m.name AS tableName, p.name AS columnName FROM sqlite_master m JOIN pragma_table_info(m.name) p
        WHERE m.type = 'table' AND p.name IN ('model', 'chatModelID', 'generationSettings')
        """).map { ($0["tableName"], $0["columnName"]) }
    }

    /// The value with `legacy/` model references (and, with `wholeIDs`, the bare `legacy` ID) named by `host`; nil
    /// when nothing changes. Values saved as JSON data are read and written as JSON.
    static func rename(_ value: Any, from legacy: String, to host: String, wholeIDs: Bool) -> Any? {
        func renamed(_ string: String) -> String {
            if wholeIDs, string == legacy { return host }
            return string.hasPrefix(legacy + "/") ? host + string.dropFirst(legacy.count) : string
        }
        func walk(_ value: Any) -> Any {
            switch value {
            case let string as String:
                renamed(string)
            case let dictionary as [String: Any]:
                Dictionary(dictionary.map { (renamed($0.key), walk($0.value)) }, uniquingKeysWith: { first, _ in first })
            case let array as [Any]:
                array.map(walk)
            default:
                value
            }
        }
        if let data = value as? Data {
            guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                  let rewritten = try? JSONSerialization.data(withJSONObject: walk(object), options: [.fragmentsAllowed]),
                  !NSDictionary(dictionary: ["v": object]).isEqual(to: ["v": walk(object)])
            else { return nil }
            return rewritten
        }
        let rewritten = walk(value)
        return NSDictionary(dictionary: ["v": value]).isEqual(to: ["v": rewritten]) ? nil : rewritten
    }

    // MARK: Rows

    /// The Desktop no longer syncs with a Dahlia Server, so a Server workspace becomes the account's like any other.
    /// Its meetings, transcripts, and files stay as they are; content the Server held alone stays missing, and its
    /// sync queue and state rows stay unread. Chats and agent rows of the Server account keep its `accountID`: it was a
    /// separate, unreleased account, so they are not merged into this one.
    static func moveServerWorkspaces(in db: Database) throws {
        // Documents of a Local workspace have no Server revision and no updates waiting to be sent.
        try db.execute(sql: """
        UPDATE document_updates SET pending = 0 WHERE pending <> 0 AND documentId IN (SELECT d.id FROM documents d
            JOIN workspaces w ON w.id = d.workspace_id WHERE w.accountConnectionId IS NOT NULL);
        UPDATE document_recoveries SET pending = 0 WHERE pending <> 0 AND documentId IN (SELECT d.id FROM documents d
            JOIN workspaces w ON w.id = d.workspace_id WHERE w.accountConnectionId IS NOT NULL);
        UPDATE documents SET generation = NULL, revision = 0
        WHERE workspace_id IN (SELECT id FROM workspaces WHERE accountConnectionId IS NOT NULL);
        UPDATE workspaces SET accountConnectionId = NULL, organizationId = NULL, personalUserId = NULL, syncRole = NULL,
            syncConfirmedConnectionId = NULL, syncPullCursor = NULL, syncLastCommittedCursor = NULL,
            syncRecoveryState = NULL, syncPullErrorJSON = NULL
        WHERE accountConnectionId IS NOT NULL OR syncConfirmedConnectionId IS NOT NULL OR syncRole IS NOT NULL;
        UPDATE workspaces SET generationSettings = json_set(generationSettings, '$.processing.location', 'local')
        WHERE json_valid(generationSettings) AND json_extract(generationSettings, '$.processing.location') = 'remote';
        """)
    }

    /// Every table that records an account moves the Databricks account's rows to the account. A row keyed by account
    /// and name (a skill's state) replaces the account's own row of that name.
    private func moveRows(from source: UUID, in db: Database) throws {
        let tables = try String.fetchAll(db, sql: """
        SELECT m.name FROM sqlite_master m JOIN pragma_table_info(m.name) p
        WHERE m.type = 'table' AND p.name = 'accountID'
        """)
        for table in tables {
            try db.execute(
                sql: "UPDATE OR REPLACE \(table.quotedDatabaseIdentifier) SET accountID = ? WHERE accountID = ?",
                arguments: [Self.accountKey, source.uuidString.lowercased()]
            )
        }
    }
}
