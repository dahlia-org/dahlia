import Foundation

/// バッチ処理の表示状態。DBの事実と実行中Coordinatorから都度導出する。
enum BatchTranscriptionState: Equatable {
    case recording(sessionId: UUID)
    case awaitingConfirmation(sessionId: UUID)
    case queued(sessionId: UUID)
    case running(sessionId: UUID)
    case completed(sessionId: UUID)
    case failed(sessionId: UUID, message: String)

    var sessionId: UUID {
        switch self {
        case let .recording(sessionId),
             let .awaitingConfirmation(sessionId),
             let .queued(sessionId),
             let .running(sessionId),
             let .completed(sessionId),
             let .failed(sessionId, _):
            sessionId
        }
    }

    var blocksSummaryGeneration: Bool {
        switch self {
        case .recording, .awaitingConfirmation, .queued, .running, .failed:
            true
        case .completed:
            false
        }
    }

    static func derive(from session: RecordingSessionRecord, isRunning: Bool = false) -> Self? {
        guard session.transcriptionMode == .batch,
              session.batchDiscardedAt == nil else { return nil }
        if session.batchCompletedAt != nil {
            return .completed(sessionId: session.id)
        }
        if isRunning {
            return .running(sessionId: session.id)
        }
        if let error = session.batchLastError?.nilIfBlank {
            return .failed(sessionId: session.id, message: error)
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
