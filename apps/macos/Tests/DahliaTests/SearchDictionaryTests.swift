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
            #expect(pending.preferred.userDictionaryName == "input.csv")
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
            try await service.select(SearchDictionaryConfiguration())
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
            let before = try Self.indexState(in: database.dbQueue)
            let source = directory.appending(path: "bad.csv")
            for text in ["", " \n", "invalid", "x,y\n", "ダリア会議,65535,65535,-10000,名詞,固有名詞,一般,*,*,*,ダリア会議,ダリアカイギ,ダリアカイギ\n"] {
                try Data(text.utf8).write(to: source)
                await #expect(throws: (any Error).self) { try await service.importUserDictionary(from: source) }
            }
            await #expect(throws: SearchDictionaryError.checksumMismatch) { try await service.installNeologd(archive: source) }
            let snapshot = try await service.snapshot()
            #expect(snapshot.preferred == SearchDictionaryConfiguration())
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
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                try await service.select(SearchDictionaryConfiguration(userDictionaryPath: "/missing.csv"))
            }
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(try await service.snapshot().preferred == SearchDictionaryConfiguration())
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
