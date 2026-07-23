import Foundation

/// バッチ処理の表示状態。DBの事実と実行中Coordinatorから都度導出する。
enum BatchTranscriptionState: Equatable {
    case recording(sessionId: UUID)
    case awaitingConfirmation(sessionId: UUID)
    case queued(sessionId: UUID)
    case running(sessionId: UUID, progress: BatchTranscriptionProgress? = nil)
    case completed(sessionId: UUID)
    case failed(sessionId: UUID, message: String)
    case retranscriptionFailed(sessionId: UUID, message: String)

    var sessionId: UUID {
        switch self {
        case let .recording(sessionId),
             let .awaitingConfirmation(sessionId),
             let .queued(sessionId),
             let .running(sessionId, _),
             let .completed(sessionId),
             let .failed(sessionId, _),
             let .retranscriptionFailed(sessionId, _):
            sessionId
        }
    }

    var blocksSummaryGeneration: Bool {
        switch self {
        case .recording, .awaitingConfirmation, .queued, .running, .failed, .retranscriptionFailed:
            true
        case .completed:
            false
        }
    }

    func preferringMoreAdvancedRunningProgress(over restoredState: Self) -> Self {
        guard sessionId == restoredState.sessionId,
              case let .running(_, currentProgress?) = self,
              case let .running(_, restoredProgress) = restoredState else {
            return restoredState
        }
        guard let restoredProgress else { return self }
        guard currentProgress.totalFileCount == restoredProgress.totalFileCount,
              currentProgress.completedFileCount >= restoredProgress.completedFileCount else {
            return restoredState
        }
        return self
    }

    static func derive(from session: RecordingSessionRecord, isRunning: Bool = false) -> Self? {
        guard session.transcriptionMode == .batch,
              session.batchDiscardedAt == nil else { return nil }
        let isRetranscription = session.isBatchRetranscriptionPending
        if isRunning {
            return .running(sessionId: session.id)
        }
        if session.batchCompletedAt != nil, !isRetranscription {
            return .completed(sessionId: session.id)
        }
        if let error = session.batchLastError?.nilIfBlank {
            return isRetranscription
                ? .retranscriptionFailed(sessionId: session.id, message: error)
                : .failed(sessionId: session.id, message: error)
        }
        if session.endedAt == nil {
            return .recording(sessionId: session.id)
        }
        if session.batchLastAttemptAt == nil {
            return .awaitingConfirmation(sessionId: session.id)
        }
        return .queued(sessionId: session.id)
    }
}
