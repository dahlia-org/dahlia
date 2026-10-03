import Charts
import SwiftUI

struct ConversationAnalyticsPaceCard: View {
    let metrics: MeetingConversationMetrics

    var body: some View {
        let microphone = metrics.source(.microphone)
        let system = metrics.source(.system)
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.conversationAnalyticsSpeakingPace)
                .font(.headline)
            paceChart(microphone: microphone, system: system)
            VStack(spacing: 8) {
                sourceFacts(
                    title: L10n.conversationAnalyticsYou,
                    systemImage: "mic.fill",
                    color: .blue,
                    source: microphone
                )
                sourceFacts(
                    title: L10n.conversationAnalyticsOtherSide,
                    systemImage: "speaker.wave.2.fill",
                    color: .orange,
                    source: system
                )
            }
            Text(paceComparison(microphone: microphone, system: system))
                .font(.body)
        }
        .frame(maxWidth: .infinity, minHeight: 236, alignment: .topLeading)
        .padding(16)
        .dahliaCardSurface()
    }

    private func paceChart(
        microphone: MeetingConversationMetrics.SourceMetrics,
        system: MeetingConversationMetrics.SourceMetrics
    ) -> some View {
        let microphonePace = microphone.charactersPerMinute ?? 0
        let systemPace = system.charactersPerMinute ?? 0
        let maximum = max(microphonePace, systemPace, 1)
        return Chart {
            paceMark(
                source: microphone,
                title: L10n.conversationAnalyticsYou,
                value: microphonePace,
                color: .blue
            )
            paceMark(
                source: system,
                title: L10n.conversationAnalyticsOtherSide,
                value: systemPace,
                color: .orange
            )
        }
        .chartXScale(domain: 0 ... maximum * 1.35)
        .chartXAxis(.hidden)
        .chartLegend(.hidden)
        .frame(height: 92)
        .accessibilityLabel(L10n.conversationAnalyticsSpeakingPace)
    }

    private func paceMark(
        source: MeetingConversationMetrics.SourceMetrics,
        title: String,
        value: Double,
        color: Color
    ) -> some ChartContent {
        BarMark(
            x: .value(L10n.charactersPerMinute, value),
            y: .value(L10n.conversationAnalyticsSourceDetails, title)
        )
        .foregroundStyle(color)
        .clipShape(.rect(cornerRadius: 4))
        .annotation(position: .trailing, alignment: .leading) {
            Text(pace(source))
                .font(.body.weight(.bold))
                .monospacedDigit()
        }
        .accessibilityLabel(title)
        .accessibilityValue(pace(source))
    }

    private func sourceFacts(
        title: String,
        systemImage: String,
        color: Color,
        source: MeetingConversationMetrics.SourceMetrics
    ) -> some View {
        let facts = L10n.conversationAnalyticsSourceFacts(
            source.normalizedCharacterCount.formatted(),
            Formatters.elapsedMinutesSeconds(duration: source.speechDuration),
            source.segmentCount.formatted()
        )
        return Label {
            Text("\(title): \(facts)")
        } icon: {
            Image(systemName: systemImage)
                .dahliaFixedSymbol()
                .foregroundStyle(color)
        }
        .font(.callout)
        .foregroundStyle(DahliaDesign.secondaryTextColor)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func paceComparison(
        microphone: MeetingConversationMetrics.SourceMetrics,
        system: MeetingConversationMetrics.SourceMetrics
    ) -> String {
        guard let microphonePace = microphone.charactersPerMinute,
              let systemPace = system.charactersPerMinute,
              systemPace > 0 else {
            return L10n.conversationAnalyticsPeerPaceUnavailable
        }
        return L10n.conversationAnalyticsPeerPaceComparison(
            systemPace.formatted(.number.precision(.fractionLength(0))),
            (microphonePace / systemPace).formatted(.number.precision(.fractionLength(2)))
        )
    }

    private func pace(_ source: MeetingConversationMetrics.SourceMetrics) -> String {
        guard let pace = source.charactersPerMinute else { return L10n.notAvailable }
        let prefix = source.unmeasurableSegmentCount > 0 ? "≈" : ""
        return "\(prefix)\(pace.formatted(.number.precision(.fractionLength(0)))) \(L10n.charactersPerMinute)"
    }
}
