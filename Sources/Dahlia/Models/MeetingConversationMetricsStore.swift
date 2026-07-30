import Combine
import Foundation
import GRDB

@MainActor
final class MeetingConversationMetricsStore: ObservableObject {
    typealias MetricsLoader = @Sendable (UUID, DatabaseQueue) async throws -> MeetingConversationMetrics

    @Published private(set) var metrics: MeetingConversationMetrics?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var reloadToken = 0

    private var meetingId: UUID?
    private var generation = 0
    private let metricsLoader: MetricsLoader

    init(metricsLoader: @escaping MetricsLoader = { meetingId, dbQueue in
        let worker = Task.detached(priority: .userInitiated) {
            try MeetingRepository(dbQueue: dbQueue)
                .loadOrRebuildConversationMetrics(meetingId: meetingId)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }) {
        self.metricsLoader = metricsLoader
    }

    func reset(for meetingId: UUID?) {
        generation += 1
        self.meetingId = meetingId
        metrics = nil
        isLoading = false
        errorMessage = nil
        reloadToken += 1
    }

    func invalidate(meetingId: UUID) {
        guard self.meetingId == meetingId else { return }
        generation += 1
        metrics = nil
        errorMessage = nil
        reloadToken += 1
    }

    func load(meetingId: UUID, dbQueue: DatabaseQueue) async {
        if self.meetingId != meetingId {
            reset(for: meetingId)
        }
        generation += 1
        let currentGeneration = generation
        isLoading = true
        errorMessage = nil
        do {
            let loaded = try await metricsLoader(meetingId, dbQueue)
            guard !Task.isCancelled,
                  self.meetingId == meetingId,
                  generation == currentGeneration else { return }
            metrics = loaded
            isLoading = false
        } catch is CancellationError {
            guard generation == currentGeneration else { return }
            isLoading = false
        } catch {
            guard self.meetingId == meetingId,
                  generation == currentGeneration else { return }
            metrics = nil
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }
}
