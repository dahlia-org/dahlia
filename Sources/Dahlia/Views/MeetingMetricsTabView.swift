import GRDB
import SwiftUI

struct MeetingMetricsTabView: View {
    let meetingId: UUID
    @State private var coordinator: MeetingMetricsCoordinator

    init(meetingId: UUID, dbQueue: DatabaseQueue) {
        self.meetingId = meetingId
        _coordinator = State(initialValue: MeetingMetricsCoordinator(dbQueue: dbQueue))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                stateContent
                if let result = coordinator.result {
                    breakdown(result)
                }
                caveats
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: meetingId) {
            coordinator.activate(meetingId: meetingId)
        }
        .onDisappear {
            coordinator.deactivate()
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch coordinator.phase {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 120)
        case .empty:
            unavailable(L10n.meetingMetricsInsufficientTranscript)
        case .failed:
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(L10n.meetingMetricsLoadFailed)
                Spacer()
                Button(L10n.retry) { coordinator.retry() }
                    .buttonStyle(.borderless)
            }
            .padding(12)
        case .ready:
            readyContent
        }
    }

    @ViewBuilder
    private var readyContent: some View {
        if let insights = coordinator.insights {
            switch insights.availability {
            case .insufficientTranscript:
                unavailable(L10n.meetingMetricsInsufficientTranscript)
            case .insufficientCoverage:
                unavailable(L10n.meetingMetricsInsufficientCoverage)
            case .ok:
                let cards = coordinator.localizedCards()
                if cards.isEmpty {
                    findingCard(
                        title: L10n.meetingMetricsNoNotablePattern,
                        detail: L10n.meetingMetricsSourceEstimateDetail,
                        evidence: ""
                    )
                } else {
                    ForEach(cards) { card in
                        findingCard(title: card.title, detail: card.detail, evidence: card.evidence)
                    }
                }
            }
        }
    }

    private func findingCard(title: String, detail: String, evidence: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
            if !evidence.isEmpty {
                Text(evidence).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .customerIntelligenceCardSurface()
    }

    private func unavailable(_ text: String) -> some View {
        ContentUnavailableView {
            Label(L10n.meetingMetrics, systemImage: "chart.bar.xaxis")
        } description: {
            Text(text)
        }
        .frame(maxWidth: .infinity, minHeight: 140)
    }

    private func breakdown(_ result: MeetingMetricsResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent(L10n.meetingMetricsConversationTalkTime) {
                Text(MeetingMetricsCoordinator.duration(result.conversationTalkSeconds)).monospacedDigit()
            }
            sourceBreakdown(L10n.microphone, row: result.source(.microphone))
            sourceBreakdown(L10n.systemAudio, row: result.source(.system))
            LabeledContent(L10n.meetingMetricsSimultaneousSourceTime) {
                Text(result.overlapSeconds.map(MeetingMetricsCoordinator.duration) ?? "—").monospacedDigit()
            }
        }
        .padding(14)
        .customerIntelligenceCardSurface()
    }

    private func sourceBreakdown(_ title: String, row: MeetingSourceMetricsRow?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            LabeledContent(L10n.meetingMetricsSpeakingTime) {
                Text(row.map { MeetingMetricsCoordinator.duration($0.speakingSeconds) } ?? "—").monospacedDigit()
            }
            LabeledContent(L10n.meetingMetricsTurnCount) {
                Text(row.map { String($0.turnCount) } ?? "—").monospacedDigit()
            }
            Text(L10n.meetingMetricsCharactersAndPaceValue(
                row.map { String($0.characterCount) } ?? "—",
                row?.charactersPerMinute.map { String(Int($0.rounded())) } ?? "—"
            ))
            .monospacedDigit()
        }
    }

    private var caveats: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.meetingMetricsSourceCaveat)
            Text(L10n.meetingMetricsSourceApproximationCaveat)
            Text(L10n.meetingMetricsEchoCancellationCaveat)
            Text(L10n.meetingMetricsBetaCaveat)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
