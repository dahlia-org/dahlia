import DahliaMeetingAccess
import Foundation
import GRDB
import Observation

@MainActor
@Observable
final class SearchSettingsModel {
    private(set) var phase = "pending"
    private(set) var completedCount = 0
    private(set) var totalCount = 0
    private(set) var pendingJobCount = 0
    private(set) var processingJobCount = 0
    private(set) var lastErrorCode: String?
    private(set) var lastImageAnalysisError: String?
    private(set) var isRequestingRebuild = false

    @ObservationIgnored private let database: AppDatabaseManager?
    @ObservationIgnored private let failureReporter: BackgroundJobWorker.FailureReporter
    @ObservationIgnored private var reportedFailures: Set<SearchFailureDiagnostic> = []

    init(
        database: AppDatabaseManager?,
        failureReporter: @escaping BackgroundJobWorker.FailureReporter = { ErrorReportingService.captureSearchFailure($0) }
    ) {
        self.database = database
        self.failureReporter = failureReporter
    }

    var progress: Double {
        guard totalCount > 0 else { return phase == "ready" ? 1 : 0 }
        return min(1, Double(completedCount) / Double(totalCount))
    }

    func refresh() async {
        guard let database else { return }
        do {
            let snapshot = try await database.dbQueue.read { db -> SearchIndexSettingsSnapshot in
                let state = try Row.fetchOne(db, sql: "SELECT * FROM search_index_state WHERE indexKind = 'fts'")
                return try SearchIndexSettingsSnapshot(
                    phase: state?["phase"] ?? "pending",
                    completedCount: state?["completedCount"] ?? 0,
                    totalCount: state?["totalCount"] ?? 0,
                    pendingJobCount: Int.fetchOne(
                        db,
                        sql: """
                        SELECT COUNT(*) FROM jobs_background WHERE indexKind = 'fts'
                          AND status = 'pending' AND attempts < 5
                        """
                    ) ?? 0,
                    processingJobCount: Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM jobs_background WHERE indexKind = 'fts' AND status = 'processing'"
                    ) ?? 0,
                    lastErrorCode: state?["lastErrorCode"] ?? (String.fetchOne(
                        db,
                        sql: """
                        SELECT lastErrorCode FROM jobs_background
                        WHERE indexKind = 'fts' AND targetKind != 'screenshotAnalysis' AND lastErrorCode IS NOT NULL
                        ORDER BY updatedAt DESC LIMIT 1
                        """
                    )),
                    lastImageAnalysisError: String.fetchOne(
                        db,
                        sql: """
                        SELECT lastErrorCode FROM jobs_background
                        WHERE indexKind = 'fts' AND targetKind = 'screenshotAnalysis' AND lastErrorCode IS NOT NULL
                        ORDER BY updatedAt DESC LIMIT 1
                        """
                    )
                )
            }
            phase = snapshot.phase
            completedCount = snapshot.completedCount
            totalCount = snapshot.totalCount
            pendingJobCount = snapshot.pendingJobCount
            processingJobCount = snapshot.processingJobCount
            lastErrorCode = snapshot.lastErrorCode
            switch snapshot.lastImageAnalysisError {
            case "CodexAppServerError": lastImageAnalysisError = L10n.searchLegacyImageAnalysisError
            case "CodexConfigurationError": lastImageAnalysisError = L10n.codexAccountConfigurationNotReady
            case "ScreenshotAnalysisError": lastImageAnalysisError = L10n.searchInvalidImageAnalysisResponse
            case let message? where message.hasPrefix("Requested Codex model is unavailable: "):
                lastImageAnalysisError = L10n.piRequestedModelUnavailable(String(message.dropFirst("Requested Codex model is unavailable: ".count)))
            default: lastImageAnalysisError = snapshot.lastImageAnalysisError
            }
        } catch {
            recordFailure(error)
        }
    }

    func rebuildFullTextIndex(dictionaryConfiguration: SearchDictionaryConfiguration? = nil) async {
        guard let database, !isRequestingRebuild else { return }
        isRequestingRebuild = true
        defer { isRequestingRebuild = false }
        do {
            if let dictionaryConfiguration {
                try await database.searchIndexer.changeSearchDictionaries(dictionaryConfiguration)
            } else {
                try await database.searchIndexer.requestRebuild()
            }
            await refresh()
        } catch {
            recordFailure(error)
        }
    }

    private func recordFailure(_ error: any Error) {
        guard !Task.isCancelled, let diagnostic = SearchFailureDiagnostic(error: error, operation: .indexing) else { return }
        lastErrorCode = error.localizedDescription
        if reportedFailures.insert(diagnostic).inserted {
            failureReporter(diagnostic)
        }
    }

}

private struct SearchIndexSettingsSnapshot: Sendable {
    let phase: String
    let completedCount: Int
    let totalCount: Int
    let pendingJobCount: Int
    let processingJobCount: Int
    let lastErrorCode: String?
    let lastImageAnalysisError: String?
}
