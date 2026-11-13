import DahliaMeetingAccess
import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct SearchDictionaryTests {
        @Test
        func migrationPreservesSourcesAndLeavesIndexUntouched() throws {
            let queue = try DatabaseQueue(configuration: AppDatabaseManager.configuration())
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v57_accountsTable")
            let meeting = try Self.insertMeeting(in: queue)
            let before = try Self.indexState(in: queue)
            try AppDatabaseManager.migrator.migrate(queue)
            let snapshot = try queue.read { db in
                try (
                    MeetingRecord.fetchOne(db, key: meeting.id),
                    SearchDictionaryConfiguration.read(in: db),
                    SearchDictionaryConfiguration.read(in: db, preferred: true),
                    Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_dictionary_configuration")
                )
            }
            #expect(snapshot.0 == meeting)
            #expect(snapshot.1 == SearchDictionaryConfiguration())
            #expect(snapshot.2 == SearchDictionaryConfiguration())
            #expect(snapshot.3 == 2)
            #expect(try Self.indexState(in: queue) == before)
        }

        @Test
        func initialUserDictionaryIncludesDatabricksAndDoesNotRestoreRemovedEntries() async throws {
            let directory = Self.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let database = try AppDatabaseManager(path: ":memory:")
            let service = SearchDictionaryService(database: database, directory: directory)
            let before = try Self.indexState(in: database.dbQueue)
            let initial = try await service.snapshot()
            let expected = Data("Databricks,カスタム名詞,データブリックス\n".utf8)
            #expect(try Data(contentsOf: URL(filePath: initial.userDictionaryPath)) == expected)
            #expect(try Data(contentsOf: URL(filePath: #require(initial.preferred.userDictionaryPath))) == expected)
            try initial.preferred.validate()
            #expect(initial.active == SearchDictionaryConfiguration())
            #expect(try Self.indexState(in: database.dbQueue) == before)

            try await service.clearUserDictionary()
            let reopened = SearchDictionaryService(database: database, directory: directory)
            let cleared = try await reopened.snapshot()
            #expect(cleared.preferred.userDictionaryPath == nil)
            #expect(try Data(contentsOf: URL(filePath: cleared.userDictionaryPath)).isEmpty)
            #expect(try Self.indexState(in: database.dbQueue) == before)
        }

        @Test
        func selectionWaitsForExplicitRebuildAndCanBeRemoved() async throws {
            let directory = Self.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let database = try AppDatabaseManager(path: ":memory:")
            let meeting = try Self.insertMeeting(in: database.dbQueue)
            let service = SearchDictionaryService(database: database, directory: directory)
            await database.searchIndexer.drain()
            let before = try Self.indexState(in: database.dbQueue)
            #expect(try Self.tokens(in: database.dbQueue) != ["ダリア会議"])

            let source = directory.appending(path: "input.csv")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("ダリア会議,カスタム名詞,ダリアカイギ\n".utf8).write(to: source)
            try await service.importUserDictionary(from: source)
            // Later edits to the original CSV do not change either the draft or the active dictionary.
            try Data("invalid".utf8).write(to: source)
            let pending = try await service.snapshot()
            #expect(pending.preferred.userDictionaryName == "user-dict.csv")
            #expect(pending.active.userDictionaryPath == nil)
            #expect(try Self.indexState(in: database.dbQueue) == before)
            await database.searchIndexer.drain()
            #expect(try Self.tokens(in: database.dbQueue) != ["ダリア会議"])
            #expect(try Self.indexState(in: database.dbQueue) == before)

            let reopenedService = SearchDictionaryService(database: database, directory: directory)
            #expect(try await reopenedService.snapshot().preferred == pending.preferred)
            try await database.searchIndexer.changeSearchDictionaries(pending.preferred)
            #expect(try Self.tokens(in: database.dbQueue) == ["ダリア会議"])
            let indexed = try await database.dbQueue.read { db in
                try (
                    String.fetchOne(db, sql: "SELECT phase FROM search_index_state WHERE indexKind = 'fts'"),
                    Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_documents_fts WHERE search_documents_fts MATCH ?", arguments: ["ダリア会議"]),
                    MeetingRecord.fetchOne(db, key: meeting.id)
                )
            }
            #expect(indexed.0 == "ready")
            #expect(indexed.1 == 1)
            #expect(indexed.2 == meeting)
            try await service.clearUserDictionary()
            #expect(try Self.tokens(in: database.dbQueue) == ["ダリア会議"])
            try await database.searchIndexer.changeSearchDictionaries(SearchDictionaryConfiguration())
            #expect(try Self.tokens(in: database.dbQueue) != ["ダリア会議"])
        }

        @Test
        func existingReadConnectionObservesDictionarySwitch() async throws {
            let directory = Self.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let database = try AppDatabaseManager(path: directory.appending(path: "test.sqlite").path, enablesConcurrentSearch: true)
            defer { try? database.close() }
            _ = try Self.insertMeeting(in: database.dbQueue)
            await database.searchIndexer.drain()
            var configuration = AppDatabaseManager.configuration()
            configuration.readonly = true
            let reader = try DatabaseQueue(path: database.dbQueue.path, configuration: configuration)
            defer { try? reader.close() }
            // Prime the FTS virtual table's cached tokenizer before changing its dictionary.
            _ = try await reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM search_documents_fts WHERE search_documents_fts MATCH '会議'") }
            let csv = directory.appending(path: "user.csv")
            try Data("ダリア会議,カスタム名詞,ダリアカイギ\n".utf8).write(to: csv)
            let selected = SearchDictionaryConfiguration(userDictionaryPath: csv.path, userDictionaryName: "user.csv")
            try await database.searchIndexer.changeSearchDictionaries(selected)
            #expect(try Self.tokens(in: reader) == ["ダリア会議"])
            let matches = try await reader.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_documents_fts WHERE search_documents_fts MATCH ?", arguments: ["ダリア会議"])
            }
            #expect(matches == 1)
        }

        @Test
        func invalidCSVAndChecksumLeaveSettingsAndIndexUnchanged() async throws {
            let directory = Self.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let database = try AppDatabaseManager(path: ":memory:")
            let service = SearchDictionaryService(database: database, directory: directory)
            let initial = try await service.snapshot()
            let before = try Self.indexState(in: database.dbQueue)
            let source = directory.appending(path: "bad.csv")
            for text in ["", " \n", "invalid", "x,y\n", "ダリア会議,65535,65535,-10000,名詞,固有名詞,一般,*,*,*,ダリア会議,ダリアカイギ,ダリアカイギ\n"] {
                try Data(text.utf8).write(to: source)
                await #expect(throws: (any Error).self) { try await service.importUserDictionary(from: source) }
            }
            await #expect(throws: SearchDictionaryError.checksumMismatch) { try await service.installNeologd(archive: source) }
            let snapshot = try await service.snapshot()
            #expect(snapshot.preferred == initial.preferred)
            #expect(snapshot.active == SearchDictionaryConfiguration())
            #expect(try Self.indexState(in: database.dbQueue) == before)
        }

        @Test
        func invalidSystemDictionaryDoesNotReplaceActiveConfiguration() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let before = try Self.indexState(in: database.dbQueue)
            await #expect(throws: DatabaseError.self) {
                try await database.searchIndexer.changeSearchDictionaries(SearchDictionaryConfiguration(dictionaryPath: "/missing/dictionary"))
            }
            #expect(try Self.indexState(in: database.dbQueue) == before)
            #expect(try await database.dbQueue.read { try SearchDictionaryConfiguration.read(in: $0) } == SearchDictionaryConfiguration())
        }

        @Test
        func cancelledSelectionDoesNotPersistChanges() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let service = SearchDictionaryService(database: database)
            let initial = try await service.snapshot()
            defer { try? FileManager.default.removeItem(at: URL(filePath: initial.userDictionaryPath).deletingLastPathComponent()) }
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                try await service.select(SearchDictionaryConfiguration(userDictionaryPath: "/missing.csv"))
            }
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(try await service.snapshot().preferred == initial.preferred)
        }

        @Test
        func fixedSourceCanBeReplacedWithoutChangingActiveSearch() async throws {
            let directory = Self.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let database = try AppDatabaseManager(path: ":memory:")
            _ = try Self.insertMeeting(in: database.dbQueue)
            await database.searchIndexer.drain()
            let service = SearchDictionaryService(database: database, directory: directory)
            let initial = try await service.snapshot()
            #expect(initial.userDictionaryPath == directory.appending(path: "user-dict.csv").path)
            let imported = directory.appending(path: "input.csv")
            try Data("ダリア会議,カスタム名詞,ダリアカイギ\n".utf8).write(to: imported)
            try await service.importUserDictionary(from: imported)
            let added = try await service.snapshot()
            try await database.searchIndexer.changeSearchDictionaries(added.preferred)
            #expect(try Self.tokens(in: database.dbQueue) == ["ダリア会議"])
            let activeState = try Self.indexState(in: database.dbQueue)
            let activeData = try Data(contentsOf: URL(filePath: #require(added.preferred.userDictionaryPath)))

            try Data("別の単語,カスタム名詞,ベツノタンゴ\n".utf8).write(to: URL(filePath: initial.userDictionaryPath))
            let edited = try await service.snapshot()
            #expect(edited.active == added.preferred)
            #expect(edited.preferred.userDictionaryPath != added.preferred.userDictionaryPath)
            #expect(try Data(contentsOf: URL(filePath: #require(added.preferred.userDictionaryPath))) == activeData)
            #expect(try Self.tokens(in: database.dbQueue) == ["ダリア会議"])
            #expect(try Self.indexState(in: database.dbQueue) == activeState)

            try Data("取込語,カスタム名詞,トリコミゴ\n".utf8).write(to: imported)
            try await service.importUserDictionary(from: imported)
            #expect(try String(contentsOfFile: initial.userDictionaryPath, encoding: .utf8) == "取込語,カスタム名詞,トリコミゴ\n")
            #expect(try Self.tokens(in: database.dbQueue) == ["ダリア会議"])
            try await service.clearUserDictionary()
            let removed = try await service.snapshot()
            #expect(removed.preferred.userDictionaryPath == nil)
            #expect(try Data(contentsOf: URL(filePath: initial.userDictionaryPath)).isEmpty)
            #expect(try Self.indexState(in: database.dbQueue) == activeState)
            try await database.searchIndexer.changeSearchDictionaries(removed.preferred)
            #expect(try Self.tokens(in: database.dbQueue) != ["ダリア会議"])
        }

        @Test
        func invalidImportAndExternalEditsPreserveFixedSource() async throws {
            let directory = Self.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let database = try AppDatabaseManager(path: ":memory:")
            let service = SearchDictionaryService(database: database, directory: directory)
            let initial = try await service.snapshot()
            let data = Data("新しい語,カスタム名詞,アタラシイゴ\n".utf8)
            try data.write(to: URL(filePath: initial.userDictionaryPath))
            let loaded = try await service.snapshot()
            let invalid = directory.appending(path: "bad.csv")
            try Data("bad".utf8).write(to: invalid)
            await #expect(throws: SearchDictionaryError.invalidUserDictionary) { try await service.importUserDictionary(from: invalid) }
            #expect(try Data(contentsOf: URL(filePath: initial.userDictionaryPath)) == data)
            #expect(try await service.snapshot().preferred == loaded.preferred)
            // An invalid external edit is visible and never becomes an active or preferred dictionary.
            try Data("invalid".utf8).write(to: URL(filePath: initial.userDictionaryPath))
            let broken = try await service.snapshot()
            #expect(broken.userDictionaryError != nil)
            #expect(broken.preferred == loaded.preferred)
            try await service.clearUserDictionary()
            #expect(try await service.snapshot().userDictionaryError == nil)
            try Data(repeating: 65, count: 10 * 1024 * 1024 + 1).write(to: URL(filePath: initial.userDictionaryPath))
            #expect(try await service.snapshot().userDictionaryError != nil)
            try await service.clearUserDictionary()
            #expect(try await service.snapshot().preferred.userDictionaryPath == nil)
        }

        @Test
        func searchDirectoryAdoptsLegacyFilesWithoutChangingActiveConfiguration() async throws {
            let root = Self.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let database = try AppDatabaseManager(path: root.appending(path: "test.sqlite").path)
            defer { try? database.close() }
            let legacy = root.appending(path: "SearchDictionaries")
            try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
            let csv = legacy.appending(path: "user-legacy.csv")
            let data = Data("ダリア会議,カスタム名詞,ダリアカイギ\n".utf8)
            try data.write(to: csv)
            let old = SearchDictionaryConfiguration(userDictionaryPath: csv.path, userDictionaryName: "old.csv")
            let oldService = SearchDictionaryService(database: database, directory: legacy)
            try await oldService.select(old)
            try await database.searchIndexer.changeSearchDictionaries(old)
            let before = try Self.indexState(in: database.dbQueue)
            let cachedName = SearchNeologdCatalog.fallback[0].id
            let oldCache = legacy.appending(path: cachedName)
            try FileManager.default.createDirectory(at: oldCache, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: oldCache.appending(path: "metadata.json"))
            let service = SearchDictionaryService(database: database)
            let migrated = try await service.snapshot()
            #expect(migrated.installedNeologdIDs.contains(cachedName))
            #expect(FileManager.default.fileExists(atPath: oldCache.appending(path: "metadata.json").path))
            #expect(migrated.userDictionaryPath == root.appending(path: "Search/user-dict.csv").path)
            #expect(try Data(contentsOf: URL(filePath: migrated.userDictionaryPath)) == data)
            #expect(migrated.preferred.userDictionaryPath?.contains("/Search/Snapshots/") == true)
            #expect(migrated.active == old)
            #expect(try Self.indexState(in: database.dbQueue) == before)
            #expect(try Data(contentsOf: csv) == data)
            let reopened = SearchDictionaryService(database: database)
            #expect(try await reopened.snapshot().preferred == migrated.preferred)
        }

        @Test
        func csvImportPreservesQuotedAndDetailedIPADICFields() async throws {
            let directory = Self.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let database = try AppDatabaseManager(path: ":memory:")
            let service = SearchDictionaryService(database: database, directory: directory)
            let data = Data("\u{FEFF}\"A,\"\"B\"\"\",カスタム名詞,エービー\r\n語,0,0,-10000,名詞,固有名詞,一般,*,*,*,原形,ヨミ,ハツオン\n".utf8)
            #expect(try SearchUserDictionaryCSV.validate(data))
            let source = directory.appending(path: "input.csv")
            try data.write(to: source)
            try await service.importUserDictionary(from: source)
            let imported = try await service.snapshot()
            #expect(try Data(contentsOf: URL(filePath: imported.userDictionaryPath)) == data)
            #expect(try Data(contentsOf: URL(filePath: #require(imported.preferred.userDictionaryPath))) == data)
            for invalid in ["\"unclosed,x,y", "word\"bad,x,y", "\"word\"extra,x,y", "word,x,", "word,x"] {
                #expect(throws: SearchDictionaryError.invalidUserDictionary) { try SearchUserDictionaryCSV.validate(Data(invalid.utf8)) }
            }
            #expect(try SearchUserDictionaryCSV.validate(Data()) == false)
        }

        private static func tokens(in queue: DatabaseQueue) throws -> [String] {
            try queue.read { try SearchFTS5Tokenizer.queryTokens(for: "ダリア会議", in: $0) }
        }

        private static func indexState(in queue: DatabaseQueue) throws -> [String] {
            try queue.read { db in
                let row = try Row.fetchOne(db, sql: "SELECT * FROM search_index_state WHERE indexKind = 'fts'")!
                return [row["phase"], String(row["indexGeneration"] as Int), String(row["indexRevision"] as Int), row["analyzerConfigurationHash"]]
            }
        }

        private static func temporaryDirectory() -> URL {
            FileManager.default.temporaryDirectory.appending(path: "dahlia-dictionary-test-\(UUID.v7())")
        }

        private static func insertMeeting(in queue: DatabaseQueue) throws -> MeetingRecord {
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            let workspace = WorkspaceRecord(id: .v7(), path: nil, name: "Test", createdAt: date, lastOpenedAt: date)
            let meeting = MeetingRecord(id: .v7(), workspaceId: workspace.id, name: "ダリア会議", createdAt: date, updatedAt: date)
            try queue.write { db in
                try workspace.insert(db)
                try meeting.insert(db)
            }
            return meeting
        }
    }
#endif
