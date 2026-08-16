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
    private(set) var isRequestingRebuild = false

    @ObservationIgnored private let database: AppDatabaseManager?

    init(database: AppDatabaseManager?) {
        self.database = database
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
                        sql: "SELECT COUNT(*) FROM search_index_jobs WHERE indexKind = 'fts' AND status = 'pending'"
                    ) ?? 0,
                    processingJobCount: Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM search_index_jobs WHERE indexKind = 'fts' AND status = 'processing'"
                    ) ?? 0,
                    lastErrorCode: state?["lastErrorCode"] ?? (String.fetchOne(
                        db,
                        sql: """
                        SELECT lastErrorCode FROM search_index_jobs
                        WHERE indexKind = 'fts' AND lastErrorCode IS NOT NULL
                        ORDER BY updatedAt DESC LIMIT 1
                        """
                    ))
                )
            }
            phase = snapshot.phase
            completedCount = snapshot.completedCount
            totalCount = snapshot.totalCount
            pendingJobCount = snapshot.pendingJobCount
            processingJobCount = snapshot.processingJobCount
            lastErrorCode = snapshot.lastErrorCode
        } catch {
            lastErrorCode = String(describing: type(of: error))
        }
    }

    func rebuild() async {
        guard let database, !isRequestingRebuild else { return }
        isRequestingRebuild = true
        defer { isRequestingRebuild = false }
        do {
            try await database.searchIndexer.requestRebuild()
            await refresh()
        } catch {
            lastErrorCode = String(describing: type(of: error))
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
}
