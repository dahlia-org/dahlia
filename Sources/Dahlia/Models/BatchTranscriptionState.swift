import Foundation

/// バッチ処理の表示状態。DBの事実と実行中Coordinatorから都度導出する。
enum BatchTranscriptionState: Equatable {
    case recording(sessionId: UUID)
    case awaitingConfirmation(sessionId: UUID)
    case queued(sessionId: UUID)
    case running(sessionId: UUID)
    case completed(sessionId: UUID)
    case failed(sessionId: UUID, message: String)
    case retranscriptionFailed(sessionId: UUID, message: String)

    var sessionId: UUID {
        switch self {
        case let .recording(sessionId),
             let .awaitingConfirmation(sessionId),
             let .queued(sessionId),
             let .running(sessionId),
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
