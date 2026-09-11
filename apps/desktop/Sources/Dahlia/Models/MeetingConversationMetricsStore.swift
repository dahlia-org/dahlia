import Combine
import Foundation
import GRDB

@MainActor
final class MeetingConversationMetricsStore: ObservableObject {
    enum Status: Equatable {
        case hidden
        case noTranscript
        case syncPending
        case loading
        case ready
        case recordingAudioMissing
        case failed(String)
    }

    typealias EligibilityLoader = @Sendable (UUID, DatabaseQueue) async throws
        -> ServerConversationAnalyticsService.Eligibility
    typealias MetricsLoader = @Sendable (ServerConversationAnalyticsService.Target) async throws
        -> ServerConversationAnalyticsService.Result

    @Published private(set) var metrics: MeetingConversationMetrics?
    @Published private(set) var status: Status = .hidden
    @Published private(set) var isTabAvailable = false
    @Published private(set) var reloadToken = 0
    @Published private(set) var target: ServerConversationAnalyticsService.Target?

    private var meetingID: UUID?
    private var generation = 0
    private let eligibilityLoader: EligibilityLoader
    private let metricsLoader: MetricsLoader

    init(
        eligibilityLoader: EligibilityLoader? = nil,
        metricsLoader: MetricsLoader? = nil
    ) {
        let service = ServerConversationAnalyticsService()
        self.eligibilityLoader = eligibilityLoader ?? service.eligibility
        self.metricsLoader = metricsLoader ?? service.load
    }

    func reset(for meetingID: UUID?) {
        generation += 1
        self.meetingID = meetingID
        target = nil
        metrics = nil
        status = .hidden
        isTabAvailable = false
        reloadToken += 1
    }

    func disable() {
        generation += 1
        target = nil
        metrics = nil
        status = .hidden
        isTabAvailable = false
    }

    func invalidate(meetingId: UUID) {
        guard meetingID == meetingId else { return }
        generation += 1
        target = nil
        metrics = nil
        status = isTabAvailable ? .loading : .hidden
        reloadToken += 1
    }

    func prepare(meetingID: UUID, dbQueue: DatabaseQueue) async {
        if self.meetingID != meetingID {
            reset(for: meetingID)
        }
        generation += 1
        let currentGeneration = generation
        target = nil
        metrics = nil
        status = isTabAvailable ? .loading : .hidden
        do {
            let eligibility = try await eligibilityLoader(meetingID, dbQueue)
            guard !Task.isCancelled, self.meetingID == meetingID, generation == currentGeneration else { return }
            switch eligibility {
            case .hidden:
                isTabAvailable = false
                status = .hidden
            case .noTranscript:
                isTabAvailable = true
                status = .noTranscript
            case .syncPending:
                isTabAvailable = true
                status = .syncPending
            case let .available(target):
                isTabAvailable = true
                status = .loading
                self.target = target
            }
        } catch is CancellationError {
            return
        } catch {
            guard self.meetingID == meetingID, generation == currentGeneration else { return }
            isTabAvailable = false
            status = .hidden
        }
    }

    func load() async {
        guard let target else { return }
        generation += 1
        let currentGeneration = generation
        status = .loading
        do {
            let result = try await metricsLoader(target)
            guard !Task.isCancelled, self.target == target, generation == currentGeneration else { return }
            switch result {
            case let .ready(metrics):
                self.metrics = metrics
                status = .ready
            case .recordingAudioMissing:
                metrics = nil
                status = .recordingAudioMissing
            }
        } catch is CancellationError {
            return
        } catch {
            guard self.target == target, generation == currentGeneration else { return }
            metrics = nil
            status = .failed(error.localizedDescription)
        }
    }
}
