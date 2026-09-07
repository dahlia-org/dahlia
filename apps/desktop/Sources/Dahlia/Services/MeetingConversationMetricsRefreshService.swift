import Foundation
import GRDB

enum MeetingConversationMetricsRefreshService {
    static func load(
        meetingId: UUID,
        dbQueue: DatabaseQueue,
        contentProvider: MeetingContentProvider = .shared
    ) async throws -> MeetingConversationMetrics {
        try await contentProvider.withContent(meetingId: meetingId, entities: [.transcript], dbQueue: dbQueue) {
            let worker = Task.detached(priority: Task.currentPriority) {
                try MeetingRepository(dbQueue: dbQueue).loadOrRebuildConversationMetrics(meetingId: meetingId)
            }
            return try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
        }
    }

    @discardableResult
    static func schedule(
        meetingId: UUID,
        dbQueue: DatabaseQueue
    ) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            do {
                _ = try await load(meetingId: meetingId, dbQueue: dbQueue)
            } catch {
                ErrorReportingService.captureSanitized(.meetingConversationMetrics)
            }
        }
    }
}
