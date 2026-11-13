import Foundation
import GRDB
import Synchronization
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct SearchFailureDiagnosticTests {
        @Test
        func diagnosticDropsPrivateDetailsAndUsesFixedCategories() throws {
            let cases: [(any Error, SearchFailureDiagnostic.Reason)] = [
                (PiRuntimeError.notLoggedIn, .authentication),
                (PiRuntimeError.providerAuthenticationFailed("private-token"), .authentication),
                (PiRuntimeError.requestedModelUnavailable("private-model"), .modelUnavailable),
                (PiRuntimeError.piCommandNotFound("/private/path"), .helperUnavailable),
                (PiRuntimeError.launchFailed("/private/path"), .launchFailed),
                (PiRuntimeError.processExited("private stderr"), .processExited),
                (PiRuntimeError.requestTimedOut("private-operation"), .timedOut),
                (PiRuntimeError.turnFailed("private-response"), .providerFailed),
                (PiRuntimeError.invalidProtocolResponse, .invalidResponse),
                (ScreenshotAnalysisError.invalidResponse, .invalidResponse),
                (AIConfigurationError.updateFailed("private-url"), .configuration),
                (DatabaseError(resultCode: .SQLITE_BUSY), .databaseBusy),
                (DatabaseError(resultCode: .SQLITE_LOCKED), .databaseBusy),
                (DatabaseError(resultCode: .SQLITE_CORRUPT), .databaseFailed),
                (NSError(domain: "private-domain", code: 42), .unknown),
            ]
            for (error, reason) in cases {
                let diagnostic = try #require(SearchFailureDiagnostic(error: error, operation: .imageAnalysis))
                #expect(diagnostic.reason == reason)
                let context = ErrorReportingService.searchFailureContext(diagnostic)
                #expect(context == ["source": "screenshotAnalysis", "errorCode": reason.rawValue])
                #expect(ErrorReportingService.sanitizedContext(context) == context)
            }
        }

        @Test
        func cancellationDoesNotProduceADiagnostic() {
            for error in [CancellationError(), PiRuntimeError.turnInterrupted, PiRuntimeError.backendResetForSafety] as [any Error] {
                #expect(SearchFailureDiagnostic(error: error, operation: .indexing) == nil)
            }
        }

        @Test
        func unavailableModelMessageUsesPi() {
            let message = PiRuntimeError.requestedModelUnavailable("test-model").localizedDescription
            #expect(!message.localizedCaseInsensitiveContains("codex"))
            #expect(message.contains("Pi"))
            #expect(message.contains("test-model"))
            #expect(!String(describing: type(of: PiRuntimeError.notLoggedIn)).localizedCaseInsensitiveContains("codex"))
            #expect(!String(describing: type(of: AIConfigurationError.accountNotReady)).localizedCaseInsensitiveContains("codex"))
        }

        @Test
        func indexFailuresAreReportedOncePerWorker() async throws {
            let diagnostics = Mutex<[SearchFailureDiagnostic]>([])
            let database = try AppDatabaseManager(path: ":memory:", searchFailureReporter: { diagnostic in
                diagnostics.withLock { $0.append(diagnostic) }
            })
            try await database.dbQueue.write { db in
                try db.execute(sql: "UPDATE search_index_state SET analyzerConfigurationHash = 'mismatch' WHERE indexKind = 'fts'")
            }
            await database.searchIndexer.drain()
            try await database.dbQueue.write { db in
                try db.execute(sql: "UPDATE search_index_state SET phase = 'pending' WHERE indexKind = 'fts'")
            }
            await database.searchIndexer.drain()
            let reported = diagnostics.withLock { $0 }
            #expect(reported.count == 1)
            #expect(reported.first?.operation == .indexing)
            #expect(reported.first?.reason == .unknown)
        }
    }
#endif
