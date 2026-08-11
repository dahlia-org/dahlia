import Foundation
import GRDB

enum MeetingConversationMetricsRefreshService {
    @discardableResult
    static func schedule(
        meetingId: UUID,
        dbQueue: DatabaseQueue
    ) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            do {
                _ = try MeetingRepository(dbQueue: dbQueue)
                    .loadOrRebuildConversationMetrics(meetingId: meetingId)
            } catch {
                ErrorReportingService.captureSanitized(.meetingConversationMetrics)
            }
        }
    }
}
