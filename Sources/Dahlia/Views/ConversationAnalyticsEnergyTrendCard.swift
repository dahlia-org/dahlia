import Charts
import SwiftUI

struct ConversationAnalyticsEnergyTrendCard: View {
    let metrics: MeetingConversationMetrics

    var body: some View {
        let energy = metrics.voiceAnalytics.energyTrend
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.conversationAnalyticsEnergyTrend)
                .font(.headline)
            Text(L10n.conversationAnalyticsEnergyTrendDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
            if energy.samples.isEmpty {
                Text(L10n.conversationAnalyticsEnergyTrendUnavailable)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                Chart(energy.samples) { sample in
                    let source = sourceTitle(sample.source)
                    LineMark(
                        x: .value(L10n.conversationAnalyticsElapsedTime, sample.midpoint),
                        y: .value(L10n.conversationAnalyticsRelativeDecibels, sample.value),
                        series: .value(L10n.conversationAnalyticsSourceDetails, sample.seriesID)
                    )
                    .foregroundStyle(by: .value(L10n.conversationAnalyticsSourceDetails, source))
                    .accessibilityHidden(true)
                    PointMark(
                        x: .value(L10n.conversationAnalyticsElapsedTime, sample.midpoint),
                        y: .value(L10n.conversationAnalyticsRelativeDecibels, sample.value)
                    )
                    .foregroundStyle(by: .value(L10n.conversationAnalyticsSourceDetails, source))
                    .accessibilityLabel(source)
                    .accessibilityValue(L10n.conversationAnalyticsVoiceSampleValue(
                        Formatters.elapsedMinutesSeconds(duration: sample.start),
                        Formatters.elapsedMinutesSeconds(duration: sample.end),
                        "\(sample.value.formatted(.number.precision(.fractionLength(1)))) dB"
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
                .chartYAxis { AxisMarks(position: .leading) }
                .chartLegend(position: .bottom, alignment: .leading, spacing: 12)
                .frame(minHeight: 180)
                .accessibilityLabel(L10n.conversationAnalyticsEnergyTrend)
            }
            ForEach(Array(energy.decliningSources).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { source in
                Label(
                    "\(sourceTitle(source)): \(L10n.conversationAnalyticsEnergyDeclining)",
                    systemImage: "chart.line.downtrend.xyaxis"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(16)
        .conversationAnalyticsCard()
    }

    private func sourceTitle(_ source: RecordingAudioSource) -> String {
        source == .microphone ? L10n.conversationAnalyticsYou : L10n.conversationAnalyticsOtherSide
    }
}
