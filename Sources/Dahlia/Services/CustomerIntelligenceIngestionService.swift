import Foundation
import GRDB
import os

struct CustomerIntelligenceIngestionMetrics: Equatable, Sendable {
    let observedParticipantCount: Int
    let ingestedContactCount: Int
    let skippedNonPersonCount: Int
    let skippedInvalidEmailCount: Int
    let excludedCurrentUserIdentityCount: Int
    let deduplicatedParticipantCount: Int

    static let empty = Self(
        observedParticipantCount: 0,
        ingestedContactCount: 0,
        skippedNonPersonCount: 0,
        skippedInvalidEmailCount: 0,
        excludedCurrentUserIdentityCount: 0,
        deduplicatedParticipantCount: 0
    )
}

enum CustomerIntelligenceIngestionService {
    private static let logger = Logger(subsystem: "com.dahlia", category: "CustomerIntelligence")

    @discardableResult
    static func schedule(
        calendarEvent: CalendarEvent,
        meetingId: UUID,
        vaultId: UUID,
        observedAt: Date,
        dbQueue: DatabaseQueue
    ) -> Task<Void, Never> {
        let participants = calendarEvent.participants
        return Task(priority: .utility) {
            do {
                _ = try await ingest(
                    participants: participants,
                    meetingId: meetingId,
                    vaultId: vaultId,
                    observedAt: observedAt,
                    dbQueue: dbQueue
                )
            } catch {
                ErrorReportingService.captureSanitized(.customerIntelligenceIngestion)
            }
        }
    }

    @discardableResult
    static func ingest(
        calendarEvent: CalendarEvent,
        meetingId: UUID,
        vaultId: UUID,
        observedAt: Date,
        dbQueue: DatabaseQueue
    ) async throws -> CustomerIntelligenceIngestionMetrics {
        try await ingest(
            participants: calendarEvent.participants,
            meetingId: meetingId,
            vaultId: vaultId,
            observedAt: observedAt,
            dbQueue: dbQueue
        )
    }

    private static func ingest(
        participants: [CalendarParticipant],
        meetingId: UUID,
        vaultId: UUID,
        observedAt: Date,
        dbQueue: DatabaseQueue
    ) async throws -> CustomerIntelligenceIngestionMetrics {
        guard !participants.isEmpty else {
            log(.empty)
            return .empty
        }
        let metrics = try await dbQueue.write { db in
            try CustomerIntelligencePersistence.ingest(
                participants: participants,
                meetingId: meetingId,
                vaultId: vaultId,
                observedAt: observedAt,
                in: db
            )
        }
        log(metrics)
        return metrics
    }

    private static func log(_ metrics: CustomerIntelligenceIngestionMetrics) {
        logger.debug(
            """
            Calendar participant ingestion \
            observed=\(metrics.observedParticipantCount, privacy: .public) \
            ingestedContacts=\(metrics.ingestedContactCount, privacy: .public) \
            skippedNonPerson=\(metrics.skippedNonPersonCount, privacy: .public) \
            skippedInvalidEmail=\(metrics.skippedInvalidEmailCount, privacy: .public) \
            excludedCurrentUserIdentities=\(metrics.excludedCurrentUserIdentityCount, privacy: .public) \
            deduplicated=\(metrics.deduplicatedParticipantCount, privacy: .public)
            """
        )
    }
}
