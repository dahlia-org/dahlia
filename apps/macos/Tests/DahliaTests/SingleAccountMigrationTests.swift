#if canImport(Testing)
    import DahliaRuntimeSupport
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    struct SingleAccountMigrationTests {
        enum CopyFailure: Error { case interrupted }

        @Test @MainActor
        func migrationFailureBlocksStartupUntilAFreshLaunchCanRetry() async throws {
            let fixture = try await Task.detached { try Fixture() }.value
            let startup = AppStartupModel()
            var activated = false
            await startup.start(onReady: { activated = true }) {
                try await Task.detached {
                    try SingleAccountMigration(
                        dbQueue: fixture.database.dbQueue, locator: fixture.locator, defaults: fixture.defaults,
                        loadSecret: { _ in throw CopyFailure.interrupted }, saveSecret: { _, _ in }
                    ).run()
                }.value
                Issue.record("Account consumers must not run after migration failure")
                return nil
            }
            #expect(!activated)
            guard case .failed(_, canContinue: false) = startup.state else {
                Issue.record("Expected blocking migration failure")
                return
            }
            let retry = AppStartupModel()
            await retry.start(onReady: { activated = true }) {
                try await Task.detached { try fixture.run() }.value
                return nil
            }
            #expect(retry.isReady && activated)
        }

        @Test
        func interruptedSkillCopyIsNotPublishedAndRetryCopiesTheWholeSkill() throws {
            let fixture = try Fixture()
            let migration = SingleAccountMigration(
                dbQueue: fixture.database.dbQueue, locator: fixture.locator, defaults: fixture.defaults,
                loadSecret: { fixture.secrets[$0] }, saveSecret: { fixture.secrets[$0] = $1 },
                copyItem: { source, target in
                    if source.lastPathComponent == "skills" {
                        try FileManager.default.createDirectory(at: target.appending(path: "shared"), withIntermediateDirectories: true)
                        try Data("partial".utf8).write(to: target.appending(path: "shared/SKILL.md"))
                        throw CopyFailure.interrupted
                    }
                    try FileManager.default.copyItem(at: source, to: target)
                }
            )
            #expect(throws: CopyFailure.self) { try migration.run() }
            #expect(!fixture.defaults.bool(forKey: SingleAccountMigration.completedKey))
            #expect(fixture.read("agent/skills/shared/SKILL.md") == nil)
            try fixture.run()
            #expect(fixture.read("agent/skills/shared/SKILL.md") == "databricks skill")
            #expect(fixture.read("agent/skills/notes/SKILL.md") == "local only")
        }

        @Test(arguments: [false, true])
        func failedSecretReadOrWriteLeavesMigrationRetryable(failRead: Bool) throws {
            let fixture = try Fixture()
            let migration = SingleAccountMigration(
                dbQueue: fixture.database.dbQueue, locator: fixture.locator, defaults: fixture.defaults,
                loadSecret: { key in
                    if failRead { throw CopyFailure.interrupted }
                    return fixture.secrets[key]
                },
                saveSecret: { _, _ in throw CopyFailure.interrupted }
            )
            #expect(throws: CopyFailure.self) { try migration.run() }
            #expect(!fixture.defaults.bool(forKey: SingleAccountMigration.completedKey))
            try fixture.run()
            #expect(fixture.secrets[PiLaunchSettings.secretKey(id: fixture.secretID)] == "secret")
            #expect(fixture.defaults.bool(forKey: SingleAccountMigration.completedKey))
        }

        @Test(arguments: [true, false])
        func serverArchivesAreAdoptedOnlyWhenTheirAudioIsVerifiedOnThisMac(filePresent: Bool) throws {
            let fixture = try Fixture()
            let root = fixture.root.appending(path: "audio")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let file = root.appending(path: "archive.m4a")
            try Data("prepared recording".utf8).write(to: file)
            let prepared = try RecordingArchiveEncoder.Prepared(
                relativePath: "archive.m4a", size: 18, checksum: RecordingArchiveEncoder.checksum(file),
                manifest: .init(sampleRate: 16000, frameCount: 16000, ranges: [])
            )
            if !filePresent { try FileManager.default.removeItem(at: file) }
            let sessionID = UUID.v7()
            try fixture.database.dbQueue.write { db in
                let workspace = try #require(try WorkspaceRecord.fetchOne(db))
                let meeting = MeetingRecord(id: .v7(), workspaceId: workspace.id, projectId: nil, name: "M", createdAt: .now, updatedAt: .now)
                try meeting.insert(db)
                try RecordingSessionRecord(id: sessionID, meetingId: meeting.id, startedAt: .now, offsetSeconds: 0, createdAt: .now, updatedAt: .now)
                    .insert(db)
                try RecordingArchiveRecord(
                    sessionId: sessionID, meetingId: meeting.id, workspaceId: workspace.id, connectionId: fixture.connectionID,
                    preparedJSON: String(decoding: SyncJSON.encoder.encode(["mic": prepared]), as: UTF8.self), state: "verified"
                ).insert(db)
            }
            try SingleAccountMigration(
                dbQueue: fixture.database.dbQueue, locator: fixture.locator, defaults: fixture.defaults,
                loadSecret: { fixture.secrets[$0] }, saveSecret: { fixture.secrets[$0] = $1 }, recordingRoot: root
            ).run()
            #expect(try fixture.database.dbQueue.read { try RecordingArchiveRecord.isAvailable(sessionId: sessionID, in: $0) } == filePresent)
        }

        /// A Mac that used a Databricks account, with a little Local Account data too.
        final class Fixture: @unchecked Sendable {
            // Only the test's own task touches these.
            let database: AppDatabaseManager
            let root: URL
            let locator: PiAgentDirectoryLocator
            let suite = "SingleAccountMigrationTests.\(UUID())"
            let defaults: UserDefaults
            var secrets: [String: String] = [:]
            let connectionID = UUID.v7()
            let databricksThread = UUID.v7().uuidString
            let localThread = UUID.v7().uuidString
            var key: String { connectionID.uuidString.lowercased() }

            init(lastOpenedIsDatabricks: Bool = true) throws {
                database = try AppDatabaseManager(path: ":memory:")
                root = FileManager.default.temporaryDirectory.appending(path: "dahlia-single-account-\(UUID().uuidString)")
                locator = PiAgentDirectoryLocator(applicationSupportURL: root)
                defaults = try #require(UserDefaults(suiteName: suite))
                let connection = DahliaAccountConnectionRecord(
                    DatabricksConnection(id: connectionID, host: "https://dbc-1.cloud.databricks.com"), createdAt: .now
                )
                try database.dbQueue.write { db in
                    try connection.insert(db)
                    try WorkspaceRecord(
                        id: .v7(), path: nil, name: "Local", createdAt: .now,
                        lastOpenedAt: lastOpenedIsDatabricks ? .distantPast : .now
                    ).insert(db)
                    let databricksWorkspace = WorkspaceRecord(
                        id: .v7(), path: nil, name: "Databricks", createdAt: .now,
                        lastOpenedAt: lastOpenedIsDatabricks ? .now : .distantPast
                    )
                    try databricksWorkspace.insert(db)
                    // The app no longer reads this column; released databases still hold it.
                    try db.execute(
                        sql: "UPDATE workspaces SET databricksConnectionId = ? WHERE id = ?",
                        arguments: [connectionID, databricksWorkspace.id]
                    )
                    for (id, account) in [(databricksThread, key), (localThread, "local")] {
                        try ChatThreadRecord(
                            id: id, accountID: account, projectID: nil, parentThreadID: nil, title: id,
                            model: nil, reasoningEffort: nil, createdAt: .now, updatedAt: .now
                        ).insert(db)
                    }
                    for (account, createdBy) in [(key, "databricks"), ("local", "local")] {
                        try db.execute(
                            sql: "INSERT INTO agent_skill_states (accountID, name, createdBy) VALUES (?, 'shared', ?)",
                            arguments: [account, createdBy]
                        )
                    }
                }
                try write("databricks", to: "accounts/\(key)/pi/sessions/shared/databricks.jsonl")
                try write("databricks skill", to: "accounts/\(key)/pi/skills/shared/SKILL.md")
                try write(#"{"dbc-2.cloud.databricks.com":{"type":"oauth"}}"#, to: "accounts/\(key)/pi/auth.json")
                try write("local", to: "accounts/local/pi/sessions/shared/local.jsonl")
                try write("local skill", to: "accounts/local/pi/skills/shared/SKILL.md")
                try write("local only", to: "accounts/local/pi/skills/notes/SKILL.md")
                try write(#"{"openai":{"type":"oauth"}}"#, to: "accounts/local/pi/auth.json")
                try write("device", to: "accounts/local/pi/dahlia-device-id")
                defaults.set("databricks", forKey: "agentMCPs.\(key)")
                defaults.set("local", forKey: "agentMCPs.local")
                defaults.set(Data("inference".utf8), forKey: "accountInferenceSettings.databricks.\(key)")
                let secretID = UUID()
                let settings = PiLaunchSettings(variables: [.init(id: secretID, name: "TOKEN", isSecret: true)])
                try defaults.set(JSONEncoder().encode(settings), forKey: PiLaunchSettings.defaultsKey(accountKey: key))
                secrets[PiLaunchSettings.secretKey(accountKey: key, id: secretID)] = "secret"
                self.secretID = secretID
            }

            var secretID = UUID()

            deinit {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: root)
            }

            func write(_ text: String, to path: String) throws {
                let url = root.appending(path: "Dahlia/\(path)")
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: url)
            }

            func read(_ path: String) -> String? {
                (try? Data(contentsOf: root.appending(path: "Dahlia/\(path)"))).map { String(decoding: $0, as: UTF8.self) }
            }

            func run() throws {
                try SingleAccountMigration(
                    dbQueue: database.dbQueue, locator: locator, defaults: defaults,
                    loadSecret: { self.secrets[$0] }, saveSecret: { self.secrets[$0] = $1 }
                ).run()
            }

            func threadAccounts() throws -> [String: String] {
                try database.dbQueue.read { db in
                    try Dictionary(uniqueKeysWithValues: ChatThreadRecord.fetchAll(db).map { ($0.id, $0.accountID) })
                }
            }
        }

        @Test
        func theDatabricksAccountsDataMovesToTheAccountAndItsConnectionStays() throws {
            let fixture = try Fixture()

            try fixture.run()

            #expect(try fixture.threadAccounts() == [fixture.databricksThread: "local", fixture.localThread: "local"])
            let skill = try fixture.database.dbQueue.read { db in
                try Row.fetchAll(db, sql: "SELECT accountID, createdBy FROM agent_skill_states")
            }
            #expect(skill.count == 1 && skill.first?["createdBy"] == "databricks")
            try fixture.database.dbQueue.read { db throws in
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM workspaces WHERE databricksConnectionId IS NOT NULL") == 0)
                #expect(try DahliaAccountConnectionRecord.fetchOne(db, key: fixture.connectionID) != nil)
            }
            // The account used the Databricks account's settings, so they win; the old keys stay.
            // The MCP registrations then name the connection by its host, as Pi does now.
            #expect(fixture.defaults.string(forKey: "agentMCPs.local") == "dbc-1.cloud.databricks.com")
            #expect(fixture.defaults.string(forKey: "agentMCPs.\(fixture.key)") == "databricks")
            #expect(fixture.defaults.data(forKey: "accountInferenceSettings.local") == Data("inference".utf8))
            #expect(fixture.secrets[PiLaunchSettings.secretKey(id: fixture.secretID)] == "secret")

            #expect(fixture.read("agent/sessions/shared/databricks.jsonl") == "databricks")
            #expect(fixture.read("agent/sessions/shared/local.jsonl") == "local")
            #expect(fixture.read("agent/skills/shared/SKILL.md") == "databricks skill")
            #expect(fixture.read("agent/skills/notes/SKILL.md") == "local only")
            #expect(fixture.read("agent/dahlia-device-id") == "device")
            let signIns = try JSONDecoder().decode(JSONValue.self, from: Data(fixture.read("agent/auth.json")?.utf8 ?? "".utf8))
            #expect(signIns.objectValue.map { Set($0.keys) } == ["openai", "dbc-2.cloud.databricks.com"])
            // The old folders stay for a release.
            #expect(fixture.read("accounts/local/pi/skills/shared/SKILL.md") == "local skill")
            #expect(try fixture.locator.agentURL() == fixture.locator.sharedAgentURL)
        }

        @Test
        func savedModelsAndRegistrationsNameTheConnectionByItsHost() throws {
            let fixture = try Fixture()
            try fixture.database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE chat_threads SET model = 'databricks/system.ai.claude-opus-5-5' WHERE id = ?",
                    arguments: [fixture.databricksThread]
                )
                try db.execute(sql: "UPDATE chat_threads SET model = 'openai/gpt-6-luna' WHERE id = ?", arguments: [fixture.localThread])
            }
            fixture.defaults.set(["databricks/system.ai.glm-6": true, "openai/gpt-6-luna": false], forKey: "agentGatewayModels.\(fixture.key)")
            let registrations: [String: Any] = [
                "providers": [["id": "databricks", "workspaceURL": "https://dbc-1.cloud.databricks.com"]],
                "listedServices": ["databricks": ["system.ai.github"]],
            ]
            try fixture.defaults.set(JSONSerialization.data(withJSONObject: registrations), forKey: "agentMCPs.\(fixture.key)")
            try fixture.write(#"{"databricks":[{"name":"model-services/system.ai.glm-6"}]}"#, to: "accounts/\(fixture.key)/pi/gateway-models.json")

            try fixture.run()

            let host = "dbc-1.cloud.databricks.com"
            let models = try fixture.database.dbQueue.read { db in
                try Dictionary(uniqueKeysWithValues: ChatThreadRecord.fetchAll(db).map { ($0.id, $0.model) })
            }
            #expect(models[fixture.databricksThread] == "\(host)/system.ai.claude-opus-5-5")
            #expect(models[fixture.localThread] == "openai/gpt-6-luna")
            #expect(fixture.defaults.dictionary(forKey: "agentGatewayModels.local") as? [String: Bool]
                == ["\(host)/system.ai.glm-6": true, "openai/gpt-6-luna": false])
            let saved = try JSONSerialization.jsonObject(with: #require(fixture.defaults.data(forKey: "agentMCPs.local"))) as? [String: Any]
            #expect((saved?["providers"] as? [[String: String]])?.first?["id"] == host)
            #expect((saved?["listedServices"] as? [String: [String]])?[host] == ["system.ai.github"])
            #expect(fixture.read("agent/gateway-models.json")?.contains(host) == true)
            #expect(fixture.read("agent/gateway-models.json")?.contains("\"databricks\"") == false)
        }

        @Test
        func aMacThatUsedTheLocalAccountKeepsItsDataAndMovesNoDatabricksRows() throws {
            let fixture = try Fixture(lastOpenedIsDatabricks: false)

            try fixture.run()

            #expect(try fixture.threadAccounts() == [fixture.databricksThread: fixture.key, fixture.localThread: "local"])
            #expect(fixture.defaults.string(forKey: "agentMCPs.local") == "local")
            #expect(fixture.read("agent/skills/shared/SKILL.md") == "local skill")
            #expect(fixture.read("agent/sessions/shared/databricks.jsonl") == nil)
            #expect(try fixture.database.dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM workspaces WHERE databricksConnectionId IS NOT NULL")
            } == 0)
        }

        @Test
        func aServerWorkspaceBecomesTheAccountsAndKeepsItsMeetings() throws {
            let fixture = try Fixture()
            let server = DahliaAccountConnectionRecord(id: .v7(), origin: "https://dahlia.example.com", clientID: "c", createdAt: .now)
            let workspaceID = UUID.v7()
            let meetingID = UUID.v7()
            let serverThread = UUID.v7().uuidString
            try fixture.database.dbQueue.write { db in
                try server.insert(db)
                try WorkspaceRecord(id: workspaceID, path: nil, name: "Server", createdAt: .now, lastOpenedAt: .distantPast).insert(db)
                try db.execute(sql: """
                UPDATE workspaces SET accountConnectionId = ?, organizationId = ?, syncRole = 'editor',
                    syncConfirmedConnectionId = ?, syncPullCursor = 'cursor',
                    generationSettings = json_set(generationSettings, '$.processing.location', 'remote')
                WHERE id = ?
                """, arguments: [server.id, UUID.v7(), server.id, workspaceID])
                try MeetingRecord(id: meetingID, workspaceId: workspaceID, projectId: nil, name: "M", createdAt: .now, updatedAt: .now)
                    .insert(db)
                try ChatThreadRecord(
                    id: serverThread, accountID: server.id.uuidString.lowercased(), projectID: nil, parentThreadID: nil,
                    title: "t", model: nil, reasoningEffort: nil, createdAt: .now, updatedAt: .now
                ).insert(db)
            }

            try fixture.run()
            // Every launch moves it again, which changes nothing.
            try fixture.run()

            let row = try #require(try fixture.database.dbQueue.read { db in
                try Row.fetchOne(db, sql: """
                SELECT accountConnectionId, organizationId, syncRole, syncConfirmedConnectionId, syncPullCursor,
                    json_extract(generationSettings, '$.processing.location') AS location,
                    (SELECT COUNT(*) FROM meetings WHERE workspace_id = workspaces.id) AS meetings
                FROM workspaces WHERE id = ?
                """, arguments: [workspaceID])
            })
            #expect(row["accountConnectionId"] as UUID? == nil && row["organizationId"] as UUID? == nil)
            #expect(row["syncRole"] as String? == nil && row["syncConfirmedConnectionId"] as UUID? == nil)
            #expect(row["syncPullCursor"] as String? == nil && row["location"] as String? == "local")
            #expect(row["meetings"] as Int == 1)
            // The Server account's chats were a separate account's and stay under it.
            #expect(try fixture.threadAccounts()[serverThread] == server.id.uuidString.lowercased())
        }

        @Test
        func runningAgainBeforeItCompletedReachesTheSameResult() throws {
            let fixture = try Fixture()
            try fixture.run()
            fixture.defaults.removeObject(forKey: SingleAccountMigration.completedKey)
            // Later launches keep the source though its workspace no longer names it.
            try fixture.run()

            #expect(try fixture.threadAccounts() == [fixture.databricksThread: "local", fixture.localThread: "local"])
            #expect(fixture.read("agent/skills/shared/SKILL.md") == "databricks skill")
            #expect(fixture.defaults.string(forKey: "agentMCPs.local") == "dbc-1.cloud.databricks.com")
        }

        @Test
        func aBackupRestoredFromBeforeTheMoveEndsTheSameWay() throws {
            let fixture = try Fixture()
            try fixture.run()
            fixture.defaults.set("changed later", forKey: "agentMCPs.local")
            try fixture.database.dbQueue.write { db in
                try db.execute(sql: "UPDATE chat_threads SET accountID = ? WHERE id = ?", arguments: [fixture.key, fixture.databricksThread])
                try db.execute(sql: "UPDATE workspaces SET databricksConnectionId = ? WHERE name = 'Databricks'", arguments: [fixture.connectionID])
            }

            try fixture.run()

            #expect(try fixture.threadAccounts()[fixture.databricksThread] == "local")
            #expect(try fixture.database.dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM workspaces WHERE databricksConnectionId IS NOT NULL")
            } == 0)
            // Settings moved once; a later change is not overwritten.
            #expect(fixture.defaults.string(forKey: "agentMCPs.local") == "changed later")
        }
    }
#endif
