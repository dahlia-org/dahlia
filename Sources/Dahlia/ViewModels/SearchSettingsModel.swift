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
    private(set) var vectorLastErrorCode: String?
    private(set) var isRequestingRebuild = false
    private(set) var vectorPhase = "pending"
    private(set) var vectorCompletedCount = 0
    private(set) var vectorTotalCount = 0
    private(set) var isVectorSearchEnabled = false
    private(set) var isUpdatingVectorSearchEnabled = false
    private(set) var isModelInstalled = false
    private(set) var isDownloadingModel = false
    private(set) var modelDownloadProgress = 0.0

    @ObservationIgnored private let database: AppDatabaseManager?

    init(database: AppDatabaseManager?) {
        self.database = database
    }

    var progress: Double {
        guard totalCount > 0 else { return phase == "ready" ? 1 : 0 }
        return min(1, Double(completedCount) / Double(totalCount))
    }

    var vectorProgress: Double {
        guard vectorTotalCount > 0 else { return vectorPhase == "ready" ? 1 : 0 }
        return min(1, Double(vectorCompletedCount) / Double(vectorTotalCount))
    }

    func refresh() async {
        guard let database else { return }
        do {
            let snapshot = try await database.dbQueue.read { db -> SearchIndexSettingsSnapshot in
                let state = try Row.fetchOne(db, sql: "SELECT * FROM search_index_state WHERE indexKind = 'fts'")
                let vectorState = try Row.fetchOne(
                    db,
                    sql: "SELECT * FROM search_index_state WHERE indexKind = 'vector'"
                )
                let hasCurrentVectorConfiguration = vectorState?["analyzerConfigurationHash"] as String?
                    == EmbeddingGemmaDescriptor.configurationHash
                let storedVectorPhase: String = vectorState?["phase"] ?? "pending"
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
                    )),
                    vectorPhase: hasCurrentVectorConfiguration ? storedVectorPhase : "pending",
                    vectorCompletedCount: hasCurrentVectorConfiguration ? vectorState?["completedCount"] ?? 0 : 0,
                    vectorTotalCount: vectorState?["totalCount"] ?? 0,
                    isVectorSearchEnabled: vectorState?["isEnabled"] ?? false,
                    vectorLastErrorCode: vectorState?["lastErrorCode"] ?? (String.fetchOne(
                        db,
                        sql: """
                        SELECT lastErrorCode FROM search_index_jobs
                        WHERE indexKind = 'vector' AND lastErrorCode IS NOT NULL
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
            vectorPhase = snapshot.vectorPhase
            vectorCompletedCount = snapshot.vectorCompletedCount
            vectorTotalCount = snapshot.vectorTotalCount
            isVectorSearchEnabled = snapshot.isVectorSearchEnabled
            if let error = snapshot.vectorLastErrorCode {
                vectorLastErrorCode = error
            } else if snapshot.vectorPhase == "ready" {
                vectorLastErrorCode = nil
            }
            isModelInstalled = await database.embeddingService.isAvailable
        } catch {
            lastErrorCode = String(describing: type(of: error))
        }
    }

    func rebuildFullTextIndex() async {
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

    func rebuildVectorIndex() async {
        guard let database, !isRequestingRebuild else { return }
        isRequestingRebuild = true
        vectorLastErrorCode = nil
        defer { isRequestingRebuild = false }
        do {
            try await database.vectorSearchIndexer.requestRebuild()
            await refresh()
        } catch {
            vectorLastErrorCode = String(describing: type(of: error))
        }
    }

    func setVectorSearchEnabled(_ isEnabled: Bool) async {
        guard let database, !isUpdatingVectorSearchEnabled,
              isEnabled != isVectorSearchEnabled else { return }
        isUpdatingVectorSearchEnabled = true
        vectorLastErrorCode = nil
        defer { isUpdatingVectorSearchEnabled = false }
        do {
            try await database.vectorSearchIndexer.setEnabled(isEnabled)
            await refresh()
        } catch {
            vectorLastErrorCode = String(describing: type(of: error))
        }
    }

    func downloadModel() async {
        guard let database, !isDownloadingModel else { return }
        isDownloadingModel = true
        modelDownloadProgress = 0
        vectorLastErrorCode = nil
        defer { isDownloadingModel = false }
        do {
            try await database.embeddingService.download { [weak self] progress in
                Task { @MainActor in self?.modelDownloadProgress = progress }
            }
            await refresh()
        } catch {
            vectorLastErrorCode = String(describing: type(of: error))
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
    let vectorPhase: String
    let vectorCompletedCount: Int
    let vectorTotalCount: Int
    let isVectorSearchEnabled: Bool
    let vectorLastErrorCode: String?
}
