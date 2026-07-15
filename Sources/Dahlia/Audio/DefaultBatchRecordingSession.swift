@preconcurrency import AVFoundation
import Foundation

/// BatchAudioRecordingSessionをrouter consumer中心のprotocolへ接続するadapter。
final class DefaultBatchRecordingSession: BatchRecordingSession {
    var events: AsyncStream<BatchRecordingEvent> {
        session.events
    }

    var targetFormat: AVAudioFormat {
        session.targetFormat
    }

    private let session: BatchAudioRecordingSession

    init(session: BatchAudioRecordingSession) {
        self.session = session
    }

    func freezeRequiredSources() async {
        await session.freezeRequiredSources()
    }

    func beginRangeConsumer(
        source: RecordingAudioSource,
        locale: Locale,
        at date: Date,
        continuingFromActiveRange: Bool
    ) async throws -> BatchRecordingConsumerAttachment {
        let range = try await session.beginRangeWithOrigin(
            source: source,
            locale: locale,
            at: date,
            continuingFromActiveRange: continuingFromActiveRange
        )
        return BatchRecordingConsumerAttachment(
            consumer: Self.consumer(writer: range.writer),
            origin: range.origin
        )
    }

    func rotateRanges(
        _ origins: [BatchRecordingRangeOrigin],
        locale: Locale
    ) async throws -> [RecordingAudioSource: BatchRecordingRangeOrigin] {
        try await session.rotateRanges(
            origins,
            locale: locale
        )
    }

    func endRangeForReconfiguration(source: RecordingAudioSource) async throws {
        try await session.endRangeForReconfiguration(source: source)
    }

    func finish() async throws {
        try await session.finish()
    }

    func cancelPreservingAudio() async {
        await session.cancelPreservingAudio()
    }

    func fullyDurableThroughOffsetSeconds() async -> TimeInterval {
        await session.fullyDurableThroughOffsetSeconds()
    }

    private static func consumer(writer: SegmentedAudioSourceWriter) -> AudioFrameRouter.BatchConsumer {
        { chunk in
            writer.appendBuffer(chunk.buffer)
        }
    }
}
