import Charts
import SwiftUI

struct ConversationAnalyticsPaceTrendCard: View {
    let metrics: MeetingConversationMetrics

    var body: some View {
        let bucketMinutes = (metrics.paceBucketDuration / 60)
            .formatted(.number.precision(.fractionLength(0)))
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.conversationAnalyticsPaceTrend)
                .font(.headline)
            Text(L10n.conversationAnalyticsPaceTrendDescription(bucketMinutes))
                .font(.callout)
                .foregroundStyle(DahliaDesign.secondaryTextColor)
            if metrics.paceSamples.isEmpty {
                Text(L10n.conversationAnalyticsPaceTrendUnavailable)
                    .foregroundStyle(DahliaDesign.secondaryTextColor)
                    .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                Chart(metrics.paceSamples) { sample in
                    let source = sourceTitle(sample.source)
                    LineMark(
                        x: .value(L10n.conversationAnalyticsElapsedTime, sample.midpoint),
                        y: .value(L10n.charactersPerMinute, sample.charactersPerMinute),
                        series: .value(L10n.conversationAnalyticsPaceSeries, sample.seriesID)
                    )
                    .foregroundStyle(by: .value(L10n.conversationAnalyticsSourceDetails, source))
                    .accessibilityHidden(true)
                    PointMark(
                        x: .value(L10n.conversationAnalyticsElapsedTime, sample.midpoint),
                        y: .value(L10n.charactersPerMinute, sample.charactersPerMinute)
                    )
                    .foregroundStyle(by: .value(L10n.conversationAnalyticsSourceDetails, source))
                    .accessibilityLabel(source)
                    .accessibilityValue(L10n.conversationAnalyticsPaceSampleValue(
                        Formatters.elapsedMinutesSeconds(duration: sample.start),
                        Formatters.elapsedMinutesSeconds(duration: sample.end),
                        sample.charactersPerMinute.formatted(.number.precision(.fractionLength(0)))
                    ))
                }
                .chartForegroundStyleScale([
                    L10n.conversationAnalyticsYou: Color.blue,
                    L10n.conversationAnalyticsOtherSide: Color.orange,
                ])
                .chartXScale(domain: 0 ... max(metrics.timelineDuration, metrics.paceBucketDuration))
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let seconds = value.as(Double.self) {
                                Text(Formatters.elapsedMinutesSeconds(duration: seconds))
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
                .chartLegend(position: .bottom, alignment: .leading, spacing: 12)
                .frame(minHeight: 180)
                .accessibilityLabel(L10n.conversationAnalyticsPaceTrend)
            }
            if metrics.hasUnmeasurableSegments {
                Label(
                    L10n.conversationAnalyticsPaceTrendExcludesUnmeasurable,
                    systemImage: "approximately"
                )
                .font(.callout)
                .foregroundStyle(DahliaDesign.secondaryTextColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(16)
        .conversationAnalyticsCard()
    }

    private func sourceTitle(_ source: RecordingAudioSource) -> String {
        switch source {
        case .microphone:
            L10n.conversationAnalyticsYou
        case .system:
            L10n.conversationAnalyticsOtherSide
        }
    }
}
