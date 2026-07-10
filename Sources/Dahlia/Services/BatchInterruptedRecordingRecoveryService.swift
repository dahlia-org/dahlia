import Foundation
import GRDB

/// クラッシュで終了時刻が未確定のバッチ録音を、確認待ちへ戻せる状態に復旧する。
enum BatchInterruptedRecordingRecoveryService {
    struct Failure {
        let sessionId: UUID
        let message: String
    }

    static func recover(
        dbQueue: DatabaseQueue,
        managedRootURL: URL
    ) async -> [Failure] {
        let sessionIds = await (try? dbQueue.read { db in
            try RecordingSessionRecord
                .filter(Column("transcriptionMode") == TranscriptionMode.batch.rawValue)
                .filter(Column("endedAt") == nil)
                .filter(Column("batchCompletedAt") == nil)
                .filter(Column("batchDiscardedAt") == nil)
                .order(Column("startedAt").asc)
                .fetchAll(db)
                .map(\.id)
        }) ?? []

        var failures: [Failure] = []
        for sessionId in sessionIds {
            do {
                try BatchTranscriptionRecoveryService.recoverAudioMetadataIfNeeded(
                    sessionId: sessionId,
                    dbQueue: dbQueue,
                    managedRootURL: managedRootURL
                )
            } catch {
                failures.append(Failure(sessionId: sessionId, message: error.localizedDescription))
                ErrorReportingService.capture(error, context: ["source": "batchRecordingRecovery"])
            }
        }
        return failures
    }
}
