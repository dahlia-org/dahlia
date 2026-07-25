import Foundation

// swiftformat:disable:next redundantSendable
/// 逐次認識パイプラインが生成する、保存先に依存しないイベント。
enum TranscriptionEvent: Equatable {
    case preview(TranscriptSegment)
    case finalized(TranscriptSegment)
    case clearPreview(sessionId: UUID, sourceLabel: String?)
    case previewTranslation(sessionId: UUID, segmentID: UUID, translatedText: String?)
    case translation(sessionId: UUID, segmentID: UUID, translatedText: String?)
    case failure(sessionId: UUID, pipelineID: UUID, sourceLabel: String?, message: String)
}

extension TranscriptionEvent {
    /// Durable backlog measurement only. Text content and identifiers are never logged.
    var durableTextByteCount: Int {
        switch self {
        case let .finalized(segment):
            segment.text.utf8.count + (segment.translatedText?.utf8.count ?? 0)
        case let .translation(_, _, translatedText):
            translatedText?.utf8.count ?? 0
        case .preview, .clearPreview, .previewTranslation, .failure:
            0
        }
    }
}
