@preconcurrency import AVFoundation
import Foundation

/// BatchAudioRecordingSessionをrouter consumer中心のprotocolへ接続するadapter。
@MainActor
final class DefaultBatchRecordingSession: BatchRecordingSession {
    var targetFormat: AVAudioFormat {
        session.targetFormat
    }

    private let session: BatchAudioRecordingSession

    init(session: BatchAudioRecordingSession) {
        self.session = session
    }

    func prepare(source: RecordingAudioSource) async throws {
        _ = try await session.prepareWriter(for: source)
    }

    func beginRangeConsumer(
        source: RecordingAudioSource,
        locale: Locale,
        at date: Date
    ) async throws -> AudioFrameRouter.BatchConsumer {
        let writer = try await session.beginRange(source: source, locale: locale, at: date)
        return Self.consumer(writer: writer)
    }

    func rotateRanges(_ origins: [BatchRecordingRangeOrigin], locale: Locale) async throws {
        try await session.rotateRanges(
            origins.map { origin in
                (
                    source: origin.source,
                    sessionRelativeOriginSeconds: origin.sessionRelativeOriginSeconds
                )
            },
            locale: locale
        )
    }

    func endRangeForReconfiguration(source: RecordingAudioSource) async throws {
        try await session.endRangeForReconfiguration(source: source)
    }

    func finish() async throws {
        try await session.finish()
    }

    func cancelAndDelete() async {
        await session.cancelAndDelete()
    }

    private static func consumer(writer: BatchAudioFileWriter) -> AudioFrameRouter.BatchConsumer {
        { chunk in
            writer.appendBuffer(chunk.buffer)
        }
    }
}
