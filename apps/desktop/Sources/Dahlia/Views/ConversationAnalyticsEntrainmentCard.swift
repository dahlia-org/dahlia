import Charts
import SwiftUI

struct ConversationAnalyticsEntrainmentCard: View {
    let metrics: MeetingConversationMetrics

    var body: some View {
        let entrainment = metrics.voiceAnalytics.pitchEntrainment
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.conversationAnalyticsPitchEntrainment)
                .font(.headline)
            Text(L10n.conversationAnalyticsPitchEntrainmentDescription)
                .font(.callout)
                .foregroundStyle(DahliaDesign.secondaryTextColor)
            if let entrainment {
                Chart(entrainment.distanceSamples) { sample in
                    LineMark(
                        x: .value(L10n.conversationAnalyticsElapsedTime, sample.midpoint),
                        y: .value(L10n.conversationAnalyticsSemitones, sample.distanceSemitones),
                        series: .value(L10n.conversationAnalyticsPitchEntrainment, sample.seriesID)
                    )
                    .foregroundStyle(.purple)
                    .accessibilityHidden(true)
                    PointMark(
                        x: .value(L10n.conversationAnalyticsElapsedTime, sample.midpoint),
                        y: .value(L10n.conversationAnalyticsSemitones, sample.distanceSemitones)
                    )
                    .foregroundStyle(.purple)
                    .accessibilityValue(L10n.conversationAnalyticsVoiceSampleValue(
                        Formatters.elapsedMinutesSeconds(duration: sample.start),
                        Formatters.elapsedMinutesSeconds(duration: sample.end),
                        sample.distanceSemitones.formatted(.number.precision(.fractionLength(1)))
                    ))
                }
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
                .frame(minHeight: 180)
                .accessibilityLabel(L10n.conversationAnalyticsPitchEntrainment)
                Label(
                    entrainment.isConverging
                        ? L10n.conversationAnalyticsPitchEntrainmentConverging
                        : L10n.conversationAnalyticsPitchEntrainmentNeutral,
                    systemImage: entrainment.isConverging ? "arrow.down.right" : "arrow.right"
                )
                .font(.body)
            } else {
                Text(L10n.conversationAnalyticsPitchEntrainmentUnavailable)
                    .foregroundStyle(DahliaDesign.secondaryTextColor)
                    .frame(maxWidth: .infinity, minHeight: 150)
            }
            Label(L10n.conversationAnalyticsPitchEntrainmentExperimental, systemImage: "flask")
                .font(.callout)
                .foregroundStyle(DahliaDesign.secondaryTextColor)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(16)
        .dahliaCardSurface()
    }
}
