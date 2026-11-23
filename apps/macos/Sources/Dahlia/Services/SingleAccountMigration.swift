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
    static let accountKey = CodexRuntimeProvider.local.accountKey

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
        }
        try dbQueue.write { db in
            if let source { try moveRows(from: source, in: db) }
            try db.execute(sql: "UPDATE workspaces SET databricksConnectionId = NULL WHERE databricksConnectionId IS NOT NULL")
        }
        defaults.set(true, forKey: Self.completedKey)
    }

    /// The Databricks account of the workspace opened last, which is the account this Mac used.
    func sourceConnectionID() throws -> UUID? {
        if let saved = defaults.string(forKey: Self.sourceKey) { return UUID(uuidString: saved) }
        let workspace = try dbQueue.read { db in
            try WorkspaceRecord.order(Column("lastOpenedAt").desc, Column("id")).fetchOne(db)
        }
        let source = workspace?.accountConnectionId == nil ? workspace?.databricksConnectionId : nil
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
        let databricks = CodexRuntimeProvider.databricks(connectionID: source)
        for variable in PiLaunchSettings.load(for: databricks, defaults: defaults).variables where variable.isSecret {
            guard let value = loadSecret(PiLaunchSettings.secretKey(for: databricks, id: variable.id)) else { continue }
            saveSecret(PiLaunchSettings.secretKey(for: .local, id: variable.id), value)
        }
    }

    // MARK: Rows

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
