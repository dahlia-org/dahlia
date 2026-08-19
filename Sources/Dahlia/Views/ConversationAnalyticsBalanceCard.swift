import Charts
import SwiftUI

struct ConversationAnalyticsBalanceCard: View {
    let metrics: MeetingConversationMetrics

    var body: some View {
        let microphone = metrics.source(.microphone)
        let system = metrics.source(.system)
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.conversationAnalyticsSpeechBalance)
                .font(.headline)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) {
                    balanceChart(microphone: microphone, system: system)
                    sourceRows(microphone: microphone, system: system)
                }
                VStack(spacing: 14) {
                    balanceChart(microphone: microphone, system: system)
                    sourceRows(microphone: microphone, system: system)
                }
            }
            if microphone.segmentCount == 0 || system.segmentCount == 0 {
                Label(L10n.conversationAnalyticsMissingSourceNote, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(DahliaDesign.secondaryTextColor)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 236, alignment: .topLeading)
        .padding(16)
        .conversationAnalyticsCard()
    }

    private func balanceChart(
        microphone: MeetingConversationMetrics.SourceMetrics,
        system: MeetingConversationMetrics.SourceMetrics
    ) -> some View {
        Chart {
            SectorMark(
                angle: .value(L10n.conversationAnalyticsYou, microphone.speechDuration),
                innerRadius: .ratio(0.66),
                angularInset: 1
            )
            .foregroundStyle(.blue)
            SectorMark(
                angle: .value(L10n.conversationAnalyticsOtherSide, system.speechDuration),
                innerRadius: .ratio(0.66),
                angularInset: 1
            )
            .foregroundStyle(.orange)
        }
        .chartLegend(.hidden)
        .frame(width: 128, height: 128)
        .overlay {
            VStack(spacing: 0) {
                Text(L10n.conversationAnalyticsYou)
                    .font(.callout)
                    .foregroundStyle(DahliaDesign.secondaryTextColor)
                Text(percentage(metrics.speechShare(for: .microphone)))
                    .font(.title3)
                    .monospacedDigit()
            }
            .accessibilityHidden(true)
        }
        .accessibilityLabel(L10n.conversationAnalyticsSpeechBalance)
        .accessibilityValue(
            L10n.conversationAnalyticsSpeakingShareSummary(
                percentage(metrics.speechShare(for: .microphone))
            )
        )
    }

    private func sourceRows(
        microphone: MeetingConversationMetrics.SourceMetrics,
        system: MeetingConversationMetrics.SourceMetrics
    ) -> some View {
        VStack(spacing: 12) {
            ConversationAnalyticsSourceRow(
                title: L10n.conversationAnalyticsYou,
                systemImage: "mic.fill",
                color: .blue,
                primaryValue: percentage(metrics.speechShare(for: .microphone)),
                facts: facts(microphone)
            )
            ConversationAnalyticsSourceRow(
                title: L10n.conversationAnalyticsOtherSide,
                systemImage: "speaker.wave.2.fill",
                color: .orange,
                primaryValue: percentage(metrics.speechShare(for: .system)),
                facts: facts(system)
            )
        }
        .frame(maxWidth: .infinity)
    }

    private func facts(_ source: MeetingConversationMetrics.SourceMetrics) -> String {
        L10n.conversationAnalyticsSourceFacts(
            source.normalizedCharacterCount.formatted(),
            Formatters.elapsedMinutesSeconds(duration: source.speechDuration),
            source.segmentCount.formatted()
        )
    }

    private func percentage(_ ratio: Double?) -> String {
        guard let ratio else { return L10n.notAvailable }
        return ratio.formatted(.percent.precision(.fractionLength(0)))
    }
}
