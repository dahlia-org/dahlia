import Charts
import SwiftUI

struct ConversationAnalyticsFlowCard: View {
    let metrics: MeetingConversationMetrics

    var body: some View {
        let microphoneIntervals = metrics.timelineIntervals.filter { $0.source == .microphone }
        let systemIntervals = metrics.timelineIntervals.filter { $0.source == .system }
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.conversationAnalyticsConversationFlow)
                .font(.headline)
            summary
            timelineChart(
                microphoneIntervals: microphoneIntervals,
                systemIntervals: systemIntervals
            )
        }
        .frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading)
        .padding(16)
        .conversationAnalyticsCard()
    }

    private var summary: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 24) {
                summaryStats
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 110), spacing: 14)],
                alignment: .leading,
                spacing: 10
            ) {
                summaryStats
            }
        }
    }

    @ViewBuilder
    private var summaryStats: some View {
        ConversationAnalyticsMetricStat(
            title: L10n.conversationAnalyticsActiveSpeech,
            value: Formatters.elapsedMinutesSeconds(duration: metrics.unionSpeechDuration)
        )
        ConversationAnalyticsMetricStat(
            title: L10n.conversationAnalyticsOccupancy,
            value: percentage(metrics.conversationOccupancyRatio)
        )
        ConversationAnalyticsMetricStat(
            title: L10n.conversationAnalyticsSimultaneousSpeech,
            value: Formatters.elapsedMinutesSeconds(duration: metrics.overlapDuration)
        )
        ConversationAnalyticsMetricStat(
            title: L10n.conversationAnalyticsOverlapRate,
            value: percentage(metrics.overlapRatio)
        )
        ConversationAnalyticsMetricStat(
            title: L10n.conversationAnalyticsOverlapCount,
            value: metrics.overlapCount.formatted()
        )
        if let monologue = metrics.longestMonologue {
            ConversationAnalyticsMetricStat(
                title: L10n.conversationAnalyticsLongestMonologue,
                value: Formatters.elapsedMinutesSeconds(duration: monologue.duration),
                detail: L10n.conversationAnalyticsMonologueDetail(
                    sourceName(monologue.source),
                    Formatters.elapsedMinutesSeconds(duration: monologue.start),
                    Formatters.elapsedMinutesSeconds(duration: monologue.end)
                )
            )
        }
    }

    private func timelineChart(
        microphoneIntervals: [MeetingConversationMetrics.TimelineInterval],
        systemIntervals: [MeetingConversationMetrics.TimelineInterval]
    ) -> some View {
        let duration = max(metrics.timelineDuration, 1)
        return Chart {
            backgroundTrack(title: L10n.conversationAnalyticsYou, duration: duration)
            backgroundTrack(title: L10n.conversationAnalyticsOtherSide, duration: duration)
            backgroundTrack(title: L10n.conversationAnalyticsOverlap, duration: duration)
            ForEach(microphoneIntervals) { interval in
                intervalMark(
                    start: interval.start,
                    end: interval.end,
                    title: L10n.conversationAnalyticsYou,
                    color: .blue
                )
            }
            ForEach(systemIntervals) { interval in
                intervalMark(
                    start: interval.start,
                    end: interval.end,
                    title: L10n.conversationAnalyticsOtherSide,
                    color: .orange
                )
            }
            ForEach(metrics.overlapIntervals) { interval in
                intervalMark(
                    start: interval.start,
                    end: interval.end,
                    title: L10n.conversationAnalyticsOverlap,
                    color: .purple
                )
            }
        }
        .chartXScale(domain: 0 ... duration)
        .chartYScale(domain: [
            L10n.conversationAnalyticsYou,
            L10n.conversationAnalyticsOtherSide,
            L10n.conversationAnalyticsOverlap,
        ])
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
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
        .chartLegend(.hidden)
        .frame(minHeight: 150)
        .accessibilityLabel(L10n.conversationAnalyticsConversationFlow)
    }

    private func backgroundTrack(title: String, duration: TimeInterval) -> some ChartContent {
        BarMark(
            xStart: .value("Start", 0),
            xEnd: .value("End", duration),
            y: .value("Source", title),
            height: .fixed(18)
        )
        .foregroundStyle(Color(nsColor: .quaternaryLabelColor))
        .cornerRadius(4)
        .accessibilityHidden(true)
    }

    private func intervalMark(
        start: TimeInterval,
        end: TimeInterval,
        title: String,
        color: Color
    ) -> some ChartContent {
        BarMark(
            xStart: .value("Start", start),
            xEnd: .value("End", end),
            y: .value("Source", title),
            height: .fixed(18)
        )
        .foregroundStyle(color)
        .cornerRadius(4)
        .accessibilityLabel(title)
        .accessibilityValue(
            "\(Formatters.elapsedMinutesSeconds(duration: start))–\(Formatters.elapsedMinutesSeconds(duration: end))"
        )
    }

    private func percentage(_ ratio: Double?) -> String {
        guard let ratio else { return L10n.notAvailable }
        return ratio.formatted(.percent.precision(.fractionLength(0)))
    }

    private func sourceName(_ source: RecordingAudioSource) -> String {
        switch source {
        case .microphone:
            L10n.conversationAnalyticsYou
        case .system:
            L10n.conversationAnalyticsOtherSide
        }
    }
}
