import Foundation
import GRDB
import Synchronization
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct SearchSettingsModelTests {
        @Test(arguments: [
            "CodexAppServerError",
            "CodexConfigurationError",
            "ScreenshotAnalysisError",
            "Requested Codex model is unavailable: legacy-model",
            "The provider rejected the request.",
        ])
        func imageAnalysisErrorsAreSeparateFromIndexFailures(imageError: String) async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            try await database.dbQueue.write { db in
                for (kind, error) in [("meeting", "sqlite:5:5"), ("screenshotAnalysis", imageError)] {
                    try db.execute(sql: """
                    INSERT INTO jobs_background(indexKind, targetKind, targetKey, availableAt, updatedAt, lastErrorCode)
                    VALUES('fts', ?, ?, ?, ?, ?)
                    """, arguments: [kind, UUID.v7(), Date(), Date(), error])
                }
            }
            let model = SearchSettingsModel(database: database)
            await model.refresh()

            #expect(model.lastErrorCode == "sqlite:5:5")
            let expected = switch imageError {
            case "CodexAppServerError": L10n.searchLegacyImageAnalysisError
            case "CodexConfigurationError": L10n.codexAccountConfigurationNotReady
            case "ScreenshotAnalysisError": L10n.searchInvalidImageAnalysisResponse
            case "Requested Codex model is unavailable: legacy-model": L10n.piRequestedModelUnavailable("legacy-model")
            default: imageError
            }
            #expect(model.lastImageAnalysisError == expected)

            try await database.dbQueue.write { db in
                try db.execute(sql: "DELETE FROM jobs_background WHERE targetKind = 'screenshotAnalysis'")
            }
            await model.refresh()
            #expect(model.lastImageAnalysisError == nil)
            #expect(model.lastErrorCode == "sqlite:5:5")
        }

        @Test
        func repeatedSettingsReadFailuresAreReportedOnce() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            try await database.dbQueue.write { db in
                try db.execute(sql: "DROP TABLE search_index_state")
            }
            let diagnostics = Mutex<[SearchFailureDiagnostic]>([])
            let model = SearchSettingsModel(database: database, failureReporter: { diagnostic in
                diagnostics.withLock { $0.append(diagnostic) }
            })
            await model.refresh()
            await model.refresh()
            let reported = diagnostics.withLock { $0 }
            #expect(reported.count == 1)
            #expect(reported.first?.operation == .indexing)
            #expect(reported.first?.reason == .databaseFailed)
        }
    }
#endif
