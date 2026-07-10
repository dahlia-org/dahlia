import Foundation

// swiftformat:disable:next redundantSendable
/// 逐次認識パイプラインが生成する、保存先に依存しないイベント。
enum TranscriptionEvent: Equatable {
    case preview(TranscriptSegment)
    case finalized(TranscriptSegment)
    case clearPreview(sessionId: UUID, sourceLabel: String?)
    case translation(sessionId: UUID, segmentID: UUID, translatedText: String?)
    case failure(sessionId: UUID, pipelineID: UUID, sourceLabel: String?, message: String)
}
