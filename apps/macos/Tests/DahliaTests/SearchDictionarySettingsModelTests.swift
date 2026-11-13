import DahliaMeetingAccess
import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct SearchDictionarySettingsModelTests {
        @Test
        func cancellingDownloadRestoresTheSavedPickerSelection() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let model = SearchDictionarySettingsModel(database: database)
            await model.refresh()
            let source = URL(filePath: model.userDictionaryPath)
            defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
            model.selectedDictionaryID = SearchNeologdCatalog.fallback[0].id
            model.selectDictionary()
            #expect(model.isDownloading)
            // Cancel before the owned task starts, so this never reaches the network.
            await model.cancelDownload()
            #expect(!model.isBusy)
            #expect(!model.isDownloading)
            #expect(model.selectedDictionaryID.isEmpty)
            #expect(model.configuration.dictionaryPath == nil)
            #expect(model.errorMessage == nil)
        }

        @Test
        func incompatibleActiveDictionaryRequiresExplicitRebuildToRecover() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let generation = try #require(try await database.dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT indexGeneration FROM search_index_state WHERE indexKind = 'fts'")
            })
            let old = SearchNeologdRelease(version: "2.3.4", sha256: String(repeating: "a", count: 64))
            try await database.dbQueue.write { db in
                try db.execute(sql: "UPDATE search_dictionary_configuration SET dictionaryPath = ? WHERE id = 1", arguments: ["/old/" + old.id])
            }
            let model = SearchDictionarySettingsModel(database: database)
            await model.refresh()
            let source = URL(filePath: model.userDictionaryPath)
            defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
            #expect(model.needsCompatibleDictionary)
            #expect(model.needsRebuild)
            #expect(model.activeDictionaryName == "IPADIC NEologd 2.3.4")
            #expect(try await database.dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT indexGeneration FROM search_index_state WHERE indexKind = 'fts'")
            } == generation)
            let selected = try #require(try await model.rebuildConfiguration())
            #expect(selected.dictionaryPath == nil)
            // Reading Settings only prepares a draft; the explicit rebuild performs the switch.
            #expect(model.needsCompatibleDictionary)
            let index = SearchSettingsModel(database: database, failureReporter: { _ in })
            await index.rebuildFullTextIndex(dictionaryConfiguration: selected)
            await model.refresh()
            #expect(!model.needsCompatibleDictionary)
            #expect(!model.needsRebuild)
            #expect(index.lastErrorCode == nil)
            #expect(try await database.dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT indexGeneration FROM search_index_state WHERE indexKind = 'fts'")
            } == generation + 1)
        }

        @Test(arguments: [false, true], [false, true])
        func explicitRebuildRereadsTheFixedSourceAndRejectsInvalidEdits(invalidOnRefresh: Bool, repairWithEmptyCSV: Bool) async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let model = SearchDictionarySettingsModel(database: database)
            #expect(!model.canRequestRebuild)
            await model.refresh()
            #expect(model.canRequestRebuild)
            #expect(model.isLoaded)
            #expect(model.isUserDictionaryValid)
            let source = URL(filePath: model.userDictionaryPath)
            defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
            let state = try await database.dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT indexGeneration FROM search_index_state WHERE indexKind = 'fts'")
            }
            try Data("ダリア会議,カスタム名詞,ダリアカイギ\n".utf8).write(to: source)
            let pending = try #require(try await model.rebuildConfiguration())
            #expect(pending.userDictionaryPath?.contains("/Snapshots/") == true)
            #expect(try Data(contentsOf: URL(filePath: #require(pending.userDictionaryPath))) == Data("ダリア会議,カスタム名詞,ダリアカイギ\n".utf8))
            #expect(model.needsRebuild)
            #expect(try await database.dbQueue.read { try SearchDictionaryConfiguration.read(in: $0) } == SearchDictionaryConfiguration())
            #expect(try await database.dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT indexGeneration FROM search_index_state WHERE indexKind = 'fts'")
            } == state)

            try Data("invalid".utf8).write(to: source)
            if invalidOnRefresh {
                await model.refresh()
            } else {
                await #expect(throws: SearchDictionaryError.invalidUserDictionary) { try await model.rebuildConfiguration() }
            }
            #expect(!model.isUserDictionaryValid)
            #expect(model.errorMessage != nil)
            #expect(!model.isBusy)
            #expect(model.canRequestRebuild)
            #expect(try await database.dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT indexGeneration FROM search_index_state WHERE indexKind = 'fts'")
            } == state)
            let repaired = repairWithEmptyCSV ? Data() : Data("修正語,カスタム名詞,シュウセイゴ\n".utf8)
            try repaired.write(to: source)
            // Retry through the same enabled action, without refreshing or reopening Settings.
            let retry = try await model.rebuildConfiguration()
            #expect(model.isUserDictionaryValid)
            #expect(model.errorMessage == nil)
            #expect(model.canRequestRebuild)
            if repairWithEmptyCSV {
                #expect(retry == nil)
            } else {
                let selected = try #require(retry)
                #expect(try Data(contentsOf: URL(filePath: #require(selected.userDictionaryPath))) == repaired)
            }
            #expect(try await database.dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT indexGeneration FROM search_index_state WHERE indexKind = 'fts'")
            } == state)
            let index = SearchSettingsModel(database: database, failureReporter: { _ in })
            await index.rebuildFullTextIndex(dictionaryConfiguration: retry)
            #expect(index.lastErrorCode == nil)
            #expect(try await database.dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT indexGeneration FROM search_index_state WHERE indexKind = 'fts'")
            } == state.map { $0 + 1 })
        }
    }
#endif
