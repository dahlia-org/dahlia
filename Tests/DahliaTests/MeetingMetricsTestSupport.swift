import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    enum MeetingMetricsTestSupport {
        static let baseDate = Date(timeIntervalSince1970: 1_776_384_000)

        static func interval(_ start: Double, _ end: Double) -> MeetingMetricsMath.Interval {
            MeetingMetricsMath.Interval(
                start: baseDate.addingTimeInterval(start),
                end: baseDate.addingTimeInterval(end)
            )
        }

        static func record(
            meetingId: UUID = .v7(),
            sessionId: UUID? = nil,
            start: Double,
            end: Double?,
            text: String = "テスト",
            confirmed: Bool = true,
            speakerLabel: String? = "mic"
        ) -> TranscriptSegmentRecord {
            TranscriptSegmentRecord(
                id: .v7(),
                meetingId: meetingId,
                sessionId: sessionId,
                startTime: baseDate.addingTimeInterval(start),
                endTime: end.map { baseDate.addingTimeInterval($0) },
                text: text,
                translatedText: nil,
                isConfirmed: confirmed,
                speakerLabel: speakerLabel
            )
        }

        // swiftlint:disable large_tuple
        static func database(
            meetingStatus: MeetingStatus = .ready,
            transcriptionMode: TranscriptionMode = .realtime,
            endedAt: Date? = nil
        ) throws -> (AppDatabaseManager, VaultRecord, MeetingRecord, RecordingSessionRecord) {
            let database = try AppDatabaseManager(path: ":memory:")
            let vault = VaultRecord(
                id: .v7(),
                path: "/tmp/meeting-metrics-\(UUID.v7().uuidString)",
                name: "Metrics",
                createdAt: baseDate,
                lastOpenedAt: baseDate
            )
            let meeting = MeetingRecord(
                id: .v7(),
                vaultId: vault.id,
                projectId: nil,
                name: "Metrics",
                status: meetingStatus,
                duration: nil,
                createdAt: baseDate,
                updatedAt: baseDate
            )
            let session = RecordingSessionRecord(
                id: .v7(),
                meetingId: meeting.id,
                startedAt: baseDate,
                endedAt: endedAt,
                duration: nil,
                offsetSeconds: 0,
                createdAt: baseDate,
                updatedAt: baseDate,
                transcriptionMode: transcriptionMode
            )
            try database.dbQueue.write { db in
                try vault.insert(db)
                try meeting.insert(db)
                try session.insert(db)
            }
            return (database, vault, meeting, session)
        }
        // swiftlint:enable large_tuple

        static func result(
            conversationTalkSeconds: Double = 300,
            overlapSeconds: Double? = 0,
            talkBalance: Double? = 0.5,
            confirmedSegmentCount: Int = 10,
            validSegmentCount: Int = 10,
            unknownSourceSegmentCount: Int = 0,
            totalCharacterCount: Int = 1000,
            validCharacterCount: Int = 1000,
            unknownSourceCharacterCount: Int = 0,
            microphone: MeetingSourceMetricsRow? = source(.microphone, seconds: 150, characters: 600, cjk: 600, turns: 4),
            system: MeetingSourceMetricsRow? = source(.system, seconds: 150, characters: 400, cjk: 400, turns: 4)
        ) -> MeetingMetricsResult {
            MeetingMetricsResult(
                meetingId: .v7(),
                metricsVersion: MeetingMetricsConstants.metricsVersion,
                transcriptRevision: 1,
                conversationTalkSeconds: conversationTalkSeconds,
                overlapSeconds: overlapSeconds,
                talkBalance: talkBalance,
                confirmedSegmentCount: confirmedSegmentCount,
                validSegmentCount: validSegmentCount,
                invalidDurationSegmentCount: confirmedSegmentCount - validSegmentCount,
                unknownSourceSegmentCount: unknownSourceSegmentCount,
                totalCharacterCount: totalCharacterCount,
                validCharacterCount: validCharacterCount,
                unknownSourceCharacterCount: unknownSourceCharacterCount,
                sourceRows: [microphone, system].compactMap { $0 }
            )
        }

        static func source(
            _ source: MetricsSource,
            seconds: Double,
            characters: Int,
            cjk: Int,
            turns: Int
        ) -> MeetingSourceMetricsRow {
            MeetingSourceMetricsRow(
                meetingId: .v7(),
                source: source,
                speakingSeconds: seconds,
                characterCount: characters,
                cjkCharacterCount: cjk,
                turnCount: turns,
                charactersPerMinute: seconds > 0 ? Double(characters) / (seconds / 60) : nil
            )
        }
    }
#endif
