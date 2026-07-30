import Foundation
import GRDB
import Observation

@Observable
@MainActor
final class MeetingMetricsCoordinator {
    enum Phase: Equatable {
        case idle
        case loading
        case waitingForStableRevision
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
    private let analyze: @Sendable (UUID, Bool) async throws -> MeetingMetricsWorker.Outcome
    private let observeRevisions: (@Sendable (UUID) async -> AsyncThrowingStream<Int64, Error>)?
    private let waitForRevisionSettle: @Sendable () async throws -> Void
    private var analysisTask: Task<Void, Never>?
    private var observationTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    private var scope: UUID?
    private var observedRevision: Int64?
    private var completedRevision: Int64?
    private var generation: UInt64 = 0

    private(set) var phase: Phase = .idle
    private(set) var isRecomputing = false
    private(set) var result: MeetingMetricsResult?
    private(set) var insights: MeetingMetricsInsightSet?
    var analysisGeneration: UInt64 { generation }

    init(dbQueue: DatabaseQueue, worker: MeetingMetricsWorker? = nil) {
        self.dbQueue = dbQueue
        let worker = worker ?? MeetingMetricsWorker(dbQueue: dbQueue)
        analyze = { meetingId, ignoringCache in
            try await worker.analyze(meetingId: meetingId, ignoringCache: ignoringCache)
        }
        observeRevisions = nil
        waitForRevisionSettle = {
            try await Task.sleep(for: MeetingMetricsConstants.revisionSettleDelay)
        }
    }

    init(
        dbQueue: DatabaseQueue,
        analyze: @escaping @Sendable (UUID, Bool) async throws -> MeetingMetricsWorker.Outcome,
        observeRevisions: (@Sendable (UUID) async -> AsyncThrowingStream<Int64, Error>)? = nil,
        waitForRevisionSettle: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(for: MeetingMetricsConstants.revisionSettleDelay)
        }
    ) {
        self.dbQueue = dbQueue
        self.analyze = analyze
        self.observeRevisions = observeRevisions
        self.waitForRevisionSettle = waitForRevisionSettle
    }

    isolated deinit {
        analysisTask?.cancel()
        observationTask?.cancel()
        settleTask?.cancel()
    }

    func activate(meetingId: UUID) {
        guard scope != meetingId else {
            startObservationIfNeeded(meetingId: meetingId)
            if analysisTask == nil, settleTask == nil, phase == .loading {
                scheduleAnalysis(meetingId: meetingId)
            }
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
        settleTask?.cancel()
        settleTask = nil
        scope = nil
        observedRevision = nil
        completedRevision = nil
        phase = .idle
        isRecomputing = false
        result = nil
        insights = nil
    }

    func retry() {
        guard let scope else { return }
        startObservationIfNeeded(meetingId: scope)
        scheduleAnalysis(meetingId: scope, ignoringCache: false)
    }

    func recompute() {
        guard let scope, !isRecomputing else { return }
        startObservationIfNeeded(meetingId: scope)
        scheduleAnalysis(meetingId: scope, ignoringCache: true)
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
        observationTask = Task { [weak self, dbQueue, observeRevisions] in
            do {
                if let observeRevisions {
                    let values = await observeRevisions(meetingId)
                    for try await revision in values {
                        guard let self, self.scope == meetingId else { return }
                        self.receiveObservedRevision(revision, meetingId: meetingId)
                    }
                } else {
                    let observation = ValueObservation.tracking { db in
                        try MeetingTranscriptRevision.current(meetingId: meetingId, in: db)
                    }
                    let values = observation
                        .removeDuplicates()
                        .values(in: dbQueue, bufferingPolicy: .bufferingNewest(1))
                    for try await revision in values {
                        guard let self, self.scope == meetingId else { return }
                        self.receiveObservedRevision(revision, meetingId: meetingId)
                    }
                }
                guard let self, self.scope == meetingId else { return }
                self.observationTask = nil
            } catch is CancellationError {
            } catch {
                guard let self, self.scope == meetingId else { return }
                self.observationTask = nil
                self.analysisTask?.cancel()
                self.analysisTask = nil
                self.settleTask?.cancel()
                self.settleTask = nil
                self.isRecomputing = false
                self.result = nil
                self.insights = nil
                self.phase = .failed
                ErrorReportingService.capture(error, context: ["source": "meetingMetricsObservation"])
            }
        }
    }

    private func receiveObservedRevision(_ revision: Int64, meetingId: UUID) {
        guard observedRevision != revision else { return }
        observedRevision = revision
        guard completedRevision != revision else { return }
        if completedRevision == nil, analysisTask == nil, settleTask == nil {
            scheduleAnalysis(meetingId: meetingId, ignoringCache: false)
        } else {
            scheduleAfterRevisionSettles(meetingId: meetingId)
        }
    }

    private func scheduleAnalysis(meetingId: UUID, ignoringCache: Bool = false) {
        generation &+= 1
        let expectedGeneration = generation
        analysisTask?.cancel()
        settleTask?.cancel()
        settleTask = nil
        isRecomputing = ignoringCache
        if !ignoringCache {
            phase = .loading
        }
        analysisTask = Task { [weak self, analyze] in
            do {
                let outcome = try await analyze(meetingId, ignoringCache)
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
                self.isRecomputing = false
                self.result = nil
                self.insights = nil
                self.phase = .failed
                ErrorReportingService.capture(error, context: ["source": "meetingMetrics"])
            }
        }
    }

    private func scheduleAfterRevisionSettles(meetingId: UUID) {
        generation &+= 1
        let expectedGeneration = generation
        analysisTask?.cancel()
        analysisTask = nil
        settleTask?.cancel()
        isRecomputing = false
        phase = .waitingForStableRevision
        settleTask = Task { [weak self, waitForRevisionSettle] in
            do {
                try await waitForRevisionSettle()
                guard let self,
                      !Task.isCancelled,
                      self.scope == meetingId,
                      self.generation == expectedGeneration else { return }
                self.settleTask = nil
                self.scheduleAnalysis(meetingId: meetingId, ignoringCache: false)
            } catch is CancellationError {
            } catch {
                guard let self,
                      self.scope == meetingId,
                      self.generation == expectedGeneration else { return }
                self.settleTask = nil
                self.result = nil
                self.insights = nil
                self.phase = .failed
                ErrorReportingService.capture(error, context: ["source": "meetingMetricsSettle"])
            }
        }
    }

    private func apply(_ outcome: MeetingMetricsWorker.Outcome, meetingId: UUID) {
        isRecomputing = false
        switch outcome {
        case let .saved(result, insights):
            completedRevision = result.transcriptRevision
            observedRevision = max(observedRevision ?? result.transcriptRevision, result.transcriptRevision)
            self.result = result
            self.insights = insights
            phase = .ready
            if observedRevision != completedRevision {
                scheduleAfterRevisionSettles(meetingId: meetingId)
            }
        case let .empty(revision):
            completedRevision = revision
            observedRevision = max(observedRevision ?? revision, revision)
            result = nil
            insights = nil
            phase = .empty
            if observedRevision != completedRevision {
                scheduleAfterRevisionSettles(meetingId: meetingId)
            }
        case let .revisionChanged(revision):
            observedRevision = max(observedRevision ?? revision, revision)
            result = nil
            insights = nil
            scheduleAfterRevisionSettles(meetingId: meetingId)
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
