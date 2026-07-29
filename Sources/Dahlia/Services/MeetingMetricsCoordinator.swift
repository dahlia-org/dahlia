import Foundation
import GRDB
import Observation

@Observable
@MainActor
final class MeetingMetricsCoordinator {
    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case empty
        case failed
    }

    struct Card: Identifiable, Equatable {
        let id: MeetingMetricsFinding.Kind
        let title: String
        let detail: String
        let evidence: String
    }

    private let dbQueue: DatabaseQueue
    private let analyze: @Sendable (UUID) async throws -> MeetingMetricsWorker.Outcome
    private var analysisTask: Task<Void, Never>?
    private var observationTask: Task<Void, Never>?
    private var scope: UUID?
    private var latestKnownRevision: Int64?
    private var generation: UInt64 = 0

    private(set) var phase: Phase = .idle
    private(set) var result: MeetingMetricsResult?
    private(set) var insights: MeetingMetricsInsightSet?

    init(dbQueue: DatabaseQueue, worker: MeetingMetricsWorker? = nil) {
        self.dbQueue = dbQueue
        let worker = worker ?? MeetingMetricsWorker(dbQueue: dbQueue)
        analyze = { meetingId in
            try await worker.analyze(meetingId: meetingId)
        }
    }

    init(
        dbQueue: DatabaseQueue,
        analyze: @escaping @Sendable (UUID) async throws -> MeetingMetricsWorker.Outcome
    ) {
        self.dbQueue = dbQueue
        self.analyze = analyze
    }

    func activate(meetingId: UUID) {
        guard scope != meetingId else {
            startObservationIfNeeded(meetingId: meetingId)
            return
        }
        deactivate()
        scope = meetingId
        phase = .loading
        startObservationIfNeeded(meetingId: meetingId)
    }

    func deactivate() {
        generation &+= 1
        analysisTask?.cancel()
        analysisTask = nil
        observationTask?.cancel()
        observationTask = nil
        scope = nil
        latestKnownRevision = nil
        phase = .idle
        result = nil
        insights = nil
    }

    func retry() {
        guard let scope else { return }
        scheduleAnalysis(meetingId: scope)
    }

    func localizedCards() -> [Card] {
        guard let insights else { return [] }
        return insights.findings.compactMap { finding in
            switch finding.evidence {
            case let .charactersPerMinute(value):
                return Card(
                    id: finding.kind,
                    title: L10n.meetingMetricsPaceTitle(Int64(value.rounded())),
                    detail: L10n.meetingMetricsPaceDetail,
                    evidence: L10n.meetingMetricsCharactersPerMinuteValue(Int64(value.rounded()))
                )
            case let .share(value):
                let percentage = Self.percentFormatter.string(from: NSNumber(value: min(max(value, 0), 1))) ?? "—"
                return Card(
                    id: finding.kind,
                    title: L10n.meetingMetricsMicrophoneShareTitle(percentage),
                    detail: L10n.meetingMetricsSourceEstimateDetail,
                    evidence: percentage
                )
            case let .overlap(seconds, share):
                let percentage = Self.percentFormatter.string(from: NSNumber(value: min(max(share, 0), 1))) ?? "—"
                let duration = Self.duration(seconds)
                return Card(
                    id: finding.kind,
                    title: L10n.meetingMetricsOverlapTitle(percentage, duration),
                    detail: L10n.meetingMetricsSourceEstimateDetail,
                    evidence: "\(percentage) · \(duration)"
                )
            }
        }
    }

    private func startObservationIfNeeded(meetingId: UUID) {
        guard observationTask == nil else { return }
        let observation = ValueObservation.tracking { db in
            try MeetingTranscriptRevision.current(meetingId: meetingId, in: db)
        }
        observationTask = Task { [weak self, dbQueue] in
            do {
                let values = observation
                    .removeDuplicates()
                    .values(in: dbQueue, bufferingPolicy: .bufferingNewest(1))
                for try await revision in values {
                    guard let self, self.scope == meetingId else { return }
                    guard self.latestKnownRevision != revision else { continue }
                    self.latestKnownRevision = revision
                    self.scheduleAnalysis(meetingId: meetingId)
                }
            } catch is CancellationError {
            } catch {
                guard let self, self.scope == meetingId else { return }
                self.phase = .failed
                ErrorReportingService.capture(error, context: ["source": "meetingMetricsObservation"])
            }
        }
    }

    private func scheduleAnalysis(meetingId: UUID) {
        generation &+= 1
        let expectedGeneration = generation
        analysisTask?.cancel()
        phase = .loading
        analysisTask = Task { [weak self, analyze] in
            do {
                let outcome = try await analyze(meetingId)
                guard let self,
                      !Task.isCancelled,
                      self.scope == meetingId,
                      self.generation == expectedGeneration else { return }
                self.analysisTask = nil
                self.apply(outcome, meetingId: meetingId)
            } catch is CancellationError {
            } catch {
                guard let self,
                      self.scope == meetingId,
                      self.generation == expectedGeneration else { return }
                self.analysisTask = nil
                self.phase = .failed
                ErrorReportingService.capture(error, context: ["source": "meetingMetrics"])
            }
        }
    }

    private func apply(_ outcome: MeetingMetricsWorker.Outcome, meetingId: UUID) {
        switch outcome {
        case let .saved(result, insights):
            latestKnownRevision = result.transcriptRevision
            self.result = result
            self.insights = insights
            phase = .ready
        case let .empty(revision):
            latestKnownRevision = revision
            result = nil
            insights = nil
            phase = .empty
        case let .revisionChanged(revision):
            latestKnownRevision = revision
            scheduleAnalysis(meetingId: meetingId)
        }
    }

    private static let percentFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    static func duration(_ seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}
