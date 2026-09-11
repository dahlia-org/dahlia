import DahliaRuntimeSupport
import DahliaServerAPI
import Foundation
import GRDB

struct ServerConversationAnalyticsService: Sendable {
    struct Target: Hashable, Sendable {
        let meetingID: UUID
        let transcriptID: UUID
        let transcriptVersion: Int
        let connectionID: UUID
        let origin: URL
    }

    enum Eligibility: Equatable, Sendable {
        case hidden
        case noTranscript
        case syncPending
        case available(Target)
    }

    enum Result: Equatable, Sendable {
        case ready(MeetingConversationMetrics)
        case recordingAudioMissing
    }

    enum Failure: LocalizedError {
        case invalidResponse

        var errorDescription: String? { L10n.conversationAnalyticsLoadFailed }
    }

    private let client: SyncAPIClient

    init(client: SyncAPIClient = SyncAPIClient(session: .shared)) {
        self.client = client
    }

    func eligibility(meetingID: UUID, dbQueue: DatabaseQueue) async throws -> Eligibility {
        let context = try await dbQueue.read { db -> (
            connectionID: UUID,
            origin: URL,
            transcript: TranscriptInfo?
        )? in
            guard let meeting = try MeetingRecord.fetchOne(db, key: meetingID),
                  let vault = try VaultRecord.fetchOne(db, key: meeting.vaultId),
                  vault.syncRole == "owner",
                  let connectionID = vault.accountConnectionId,
                  vault.syncConfirmedConnectionId == connectionID,
                  let origin = try String.fetchOne(
                      db,
                      sql: "SELECT origin FROM dahlia_account_connections WHERE id = ?",
                      arguments: [connectionID]
                  ).flatMap(URL.init(string:))
            else { return nil }
            return try (connectionID, origin, TranscriptRecord.current(meetingID, in: db))
        }
        guard let context else { return .hidden }
        let capabilities = try await client.perform(
            origin: context.origin,
            connectionId: context.connectionID,
            maximumBytes: 8192
        ) {
            try await $0.getCapabilities().ok.body.json
        }
        guard capabilities.conversationAnalytics?.version == 1 else { return .hidden }
        guard let transcript = context.transcript else { return .noTranscript }
        guard let version = transcript.version, transcript.endedAt != nil else { return .syncPending }
        return .available(Target(
            meetingID: meetingID,
            transcriptID: transcript.id,
            transcriptVersion: version,
            connectionID: context.connectionID,
            origin: context.origin
        ))
    }

    func load(_ target: Target) async throws -> Result {
        let response = try await client.perform(
            origin: target.origin,
            connectionId: target.connectionID,
            maximumBytes: 512 * 1024
        ) {
            try await $0.getConversationAnalytics(path: .init(
                meetingId: target.meetingID.uuidString.lowercased(),
                version: String(target.transcriptVersion)
            )).ok.body.json
        }
        if let ready = response.value1 {
            guard ready.transcriptId == target.transcriptID.uuidString.lowercased(),
                  ready.transcriptVersion == target.transcriptVersion,
                  let metrics = MeetingConversationMetrics(ready)
            else { throw Failure.invalidResponse }
            return .ready(metrics)
        }
        guard let unavailable = response.value2,
              unavailable.transcriptId == target.transcriptID.uuidString.lowercased(),
              unavailable.transcriptVersion == target.transcriptVersion
        else { throw Failure.invalidResponse }
        return .recordingAudioMissing
    }
}

private extension MeetingConversationMetrics {
    init?(_ response: Components.Schemas.ConversationAnalytics) {
        guard let transcriptID = UUID(uuidString: response.transcriptId),
              let calculationVersion = Int(exactly: response.calculationVersion)
        else { return nil }
        self.init(
            transcriptID: transcriptID,
            transcriptVersion: response.transcriptVersion,
            calculationVersion: calculationVersion,
            recordingDuration: response.recordingDuration,
            unionSpeechDuration: response.unionSpeechDuration,
            overlapDuration: response.overlapDuration,
            conversationOccupancyRatio: response.conversationOccupancyRatio,
            overlapRatio: response.overlapRatio,
            sources: response.sources.compactMap { source in
                guard let audioSource = RecordingAudioSource(audioSource: source.source.rawValue) else { return nil }
                return SourceMetrics(
                    source: audioSource,
                    speechDuration: source.speechDuration,
                    normalizedCharacterCount: source.normalizedCharacterCount,
                    segmentCount: source.segmentCount,
                    unmeasurableSegmentCount: source.unmeasurableSegmentCount,
                    charactersPerMinute: source.charactersPerMinute,
                    speechShare: source.speechShare
                )
            },
            speechMergeGap: response.speechMergeGap,
            monologueMergeGap: response.monologueMergeGap,
            longestMonologue: response.longestMonologue.flatMap { interval in
                guard let source = RecordingAudioSource(audioSource: interval.source.rawValue) else { return nil }
                return MonologueInterval(source: source, start: interval.start, end: interval.end)
            },
            paceSamples: response.paceSamples.compactMap { sample in
                RecordingAudioSource(audioSource: sample.source.rawValue).map {
                    PaceSample(
                        source: $0,
                        start: sample.start,
                        end: sample.end,
                        charactersPerMinute: sample.charactersPerMinute,
                        seriesIndex: sample.seriesIndex
                    )
                }
            },
            paceBucketDuration: response.paceBucketDuration,
            timelineIntervals: response.timelineIntervals.compactMap { interval in
                RecordingAudioSource(audioSource: interval.source.rawValue).map {
                    TimelineInterval(source: $0, start: interval.start, end: interval.end)
                }
            },
            overlapIntervals: response.overlapIntervals.map { OverlapInterval(start: $0.start, end: $0.end) },
            overlapCount: response.overlapCount,
            isTimelineCondensed: response.isTimelineCondensed
        )
    }
}
