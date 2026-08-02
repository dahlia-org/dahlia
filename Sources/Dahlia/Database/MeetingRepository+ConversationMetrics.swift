import Foundation
import GRDB

extension MeetingRepository {
    private struct StoredConversationMetricsInput {
        let meetingDuration: TimeInterval?
        let sessions: [RecordingSessionRecord]
        let metrics: MeetingConversationMetricsRecord?
        let sources: [MeetingConversationSourceMetricsRecord]
    }

    private nonisolated static let transcriptPageSize = 500

    nonisolated func loadOrRebuildConversationMetrics(
        meetingId: UUID,
        computedAt: Date = .now
    ) throws -> MeetingConversationMetrics {
        try Task.checkCancellation()
        let stored = try dbQueue.read { db -> StoredConversationMetricsInput in
            guard let meeting = try MeetingRecord.fetchOne(db, key: meetingId) else {
                throw CocoaError(.fileNoSuchFile)
            }
            let sessions = try RecordingSessionRecord
                .filter(Column("meetingId") == meetingId)
                .order(Column("offsetSeconds").asc, Column("startedAt").asc, Column("id").asc)
                .fetchAll(db)
            let metrics = try MeetingConversationMetricsRecord.fetchOne(db, key: meetingId)
            let sources = try MeetingConversationSourceMetricsRecord
                .filter(Column("meetingId") == meetingId)
                .order(Column("source").asc)
                .fetchAll(db)
            return StoredConversationMetricsInput(
                meetingDuration: meeting.duration,
                sessions: sessions,
                metrics: metrics,
                sources: sources
            )
        }
        let segmentRecords = try loadConversationMetricSegmentRecords(meetingId: meetingId)
        try Task.checkCancellation()
        let input = MeetingConversationMetricsInput(
            meetingDuration: stored.meetingDuration,
            sessions: stored.sessions.map {
                MeetingConversationMetricsInput.Session(
                    id: $0.id,
                    startedAt: $0.startedAt,
                    duration: $0.duration,
                    offsetSeconds: $0.offsetSeconds
                )
            },
            segments: segmentRecords.compactMap(Self.conversationMetricSegment)
        )
        let fingerprint = try input.fingerprint()
        let speechMergeGap = MeetingConversationMetricsCalculator.defaultSpeechMergeGap
        try Task.checkCancellation()
        if let metrics = stored.metrics,
           metrics.calculationVersion == MeetingConversationMetrics.calculationVersion,
           metrics.inputFingerprint == fingerprint,
           Set(stored.sources.map(\.source)) == Set([RecordingAudioSource.microphone, .system]) {
            let timeline = MeetingConversationMetricsCalculator.timelineProjection(
                input: input,
                speechMergeGap: speechMergeGap
            )
            return Self.makeConversationMetrics(
                metrics,
                sources: stored.sources,
                speechMergeGap: speechMergeGap,
                timeline: timeline
            )
        }

        let calculated = MeetingConversationMetricsCalculator.calculate(
            input: input,
            fingerprint: fingerprint,
            computedAt: computedAt,
            speechMergeGap: speechMergeGap
        )
        try Task.checkCancellation()
        try dbQueue.write { db in
            guard try MeetingRecord.fetchOne(db, key: meetingId) != nil else {
                throw CocoaError(.fileNoSuchFile)
            }
            try MeetingConversationMetricsRecord(
                meetingId: meetingId,
                calculationVersion: MeetingConversationMetrics.calculationVersion,
                inputFingerprint: calculated.inputFingerprint,
                recordingDuration: calculated.recordingDuration,
                unionSpeechDuration: calculated.unionSpeechDuration,
                overlapDuration: calculated.overlapDuration,
                usesLegacyTimelineFallback: calculated.usesLegacyTimelineFallback,
                computedAt: calculated.computedAt
            )
            .save(db)
            _ = try MeetingConversationSourceMetricsRecord
                .filter(Column("meetingId") == meetingId)
                .deleteAll(db)
            for source in calculated.sources {
                try MeetingConversationSourceMetricsRecord(
                    meetingId: meetingId,
                    source: source.source,
                    speechDuration: source.speechDuration,
                    normalizedCharacterCount: source.normalizedCharacterCount,
                    segmentCount: source.segmentCount,
                    unmeasurableSegmentCount: source.unmeasurableSegmentCount
                )
                .insert(db)
            }
        }
        return calculated
    }

    private nonisolated func loadConversationMetricSegmentRecords(
        meetingId: UUID
    ) throws -> [TranscriptSegmentRecord] {
        var records: [TranscriptSegmentRecord] = []
        var lastStartTime: Date?
        var lastID: UUID?
        while true {
            try Task.checkCancellation()
            let page = try dbQueue.read { db in
                var request = TranscriptSegmentRecord
                    .filter(Column("meetingId") == meetingId)
                    .filter(Column("isConfirmed") == true)
                    .filter(
                        Column("speakerLabel") == RecordingAudioSource.microphone.speakerLabel
                            || Column("speakerLabel") == RecordingAudioSource.system.speakerLabel
                    )
                    .order(Column("startTime").asc, Column("id").asc)
                    .limit(Self.transcriptPageSize)
                if let lastStartTime, let lastID {
                    request = request.filter(
                        Column("startTime") > lastStartTime
                            || (Column("startTime") == lastStartTime && Column("id") > lastID)
                    )
                }
                return try request.fetchAll(db)
            }
            records.append(contentsOf: page)
            guard page.count == Self.transcriptPageSize,
                  let lastRecord = page.last else {
                return records
            }
            lastStartTime = lastRecord.startTime
            lastID = lastRecord.id
        }
    }

    private nonisolated static func conversationMetricSegment(
        _ record: TranscriptSegmentRecord
    ) -> MeetingConversationMetricsInput.Segment? {
        guard let speakerLabel = record.speakerLabel else { return nil }
        return MeetingConversationMetricsInput.Segment(
            id: record.id,
            sessionId: record.sessionId,
            startTime: record.startTime,
            endTime: record.endTime,
            text: record.text,
            speakerLabel: speakerLabel,
            audioFeatures: record.audioFeatures
        )
    }

    private nonisolated static func makeConversationMetrics(
        _ metrics: MeetingConversationMetricsRecord,
        sources: [MeetingConversationSourceMetricsRecord],
        speechMergeGap: TimeInterval,
        timeline: MeetingConversationMetricsCalculator.TimelineProjection
    ) -> MeetingConversationMetrics {
        MeetingConversationMetrics(
            inputFingerprint: metrics.inputFingerprint,
            recordingDuration: metrics.recordingDuration,
            unionSpeechDuration: metrics.unionSpeechDuration,
            overlapDuration: metrics.overlapDuration,
            usesLegacyTimelineFallback: metrics.usesLegacyTimelineFallback,
            computedAt: metrics.computedAt,
            sources: sources.map {
                MeetingConversationMetrics.SourceMetrics(
                    source: $0.source,
                    speechDuration: $0.speechDuration,
                    normalizedCharacterCount: $0.normalizedCharacterCount,
                    segmentCount: $0.segmentCount,
                    unmeasurableSegmentCount: $0.unmeasurableSegmentCount
                )
            },
            speechMergeGap: speechMergeGap,
            monologueMergeGap: MeetingConversationMetricsCalculator.defaultMonologueMergeGap,
            longestMonologue: timeline.longestMonologue,
            paceSamples: timeline.paceSamples,
            paceBucketDuration: timeline.paceBucketDuration,
            timelineIntervals: timeline.intervals,
            overlapIntervals: timeline.overlaps,
            overlapCount: timeline.overlapCount,
            isTimelineCondensed: timeline.isCondensed,
            voiceAnalytics: timeline.voiceAnalytics
        )
    }
}
