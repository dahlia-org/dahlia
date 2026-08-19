import Charts
import SwiftUI

struct ConversationAnalyticsExcitementCard: View {
    let metrics: MeetingConversationMetrics

    var body: some View {
        let excitement = metrics.voiceAnalytics.excitement
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.conversationAnalyticsExcitement)
                .font(.headline)
            Text(L10n.conversationAnalyticsExcitementDescription)
                .font(.callout)
                .foregroundStyle(DahliaDesign.secondaryTextColor)
            if excitement.samples.isEmpty {
                Text(L10n.conversationAnalyticsExcitementUnavailable)
                    .foregroundStyle(DahliaDesign.secondaryTextColor)
                    .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                chart(excitement.samples)
            }
            hotspotList(excitement.hotspots)
            if !availableSources.isSubset(of: excitement.sourcesUsingPitch) {
                Label(L10n.conversationAnalyticsLoudnessOnly, systemImage: "waveform.badge.minus")
                    .font(.callout)
                    .foregroundStyle(DahliaDesign.secondaryTextColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(16)
        .dahliaCardSurface()
    }

    private var availableSources: Set<RecordingAudioSource> {
        Set(metrics.voiceAnalytics.sourceStatuses.compactMap {
            $0.availability == .available ? $0.source : nil
        })
    }

    private func chart(_ samples: [MeetingVoiceAnalytics.SourceSample]) -> some View {
        Chart {
            RuleMark(y: .value(L10n.conversationAnalyticsHotspots, 1.5))
                .foregroundStyle(DahliaDesign.secondaryTextColor)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .accessibilityHidden(true)
            ForEach(samples) { sample in
                let source = sourceTitle(sample.source)
                LineMark(
                    x: .value(L10n.conversationAnalyticsElapsedTime, sample.midpoint),
                    y: .value(L10n.conversationAnalyticsExcitement, sample.value),
                    series: .value(L10n.conversationAnalyticsSourceDetails, sample.seriesID)
                )
                .foregroundStyle(by: .value(L10n.conversationAnalyticsSourceDetails, source))
                .accessibilityHidden(true)
                PointMark(
                    x: .value(L10n.conversationAnalyticsElapsedTime, sample.midpoint),
                    y: .value(L10n.conversationAnalyticsExcitement, sample.value)
                )
                .foregroundStyle(by: .value(L10n.conversationAnalyticsSourceDetails, source))
                .accessibilityLabel(source)
                .accessibilityValue(L10n.conversationAnalyticsVoiceSampleValue(
                    Formatters.elapsedMinutesSeconds(duration: sample.start),
                    Formatters.elapsedMinutesSeconds(duration: sample.end),
                    sample.value.formatted(.number.precision(.fractionLength(1)))
                ))
            }
        }
        .chartForegroundStyleScale([
            L10n.conversationAnalyticsYou: Color.blue,
            L10n.conversationAnalyticsOtherSide: Color.orange,
        ])
        .chartXScale(domain: 0 ... max(metrics.timelineDuration, metrics.paceBucketDuration))
        .chartYScale(domain: -3 ... 3)
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
        .accessibilityLabel(L10n.conversationAnalyticsExcitement)
    }

    @ViewBuilder
    private func hotspotList(_ hotspots: [MeetingVoiceAnalytics.Hotspot]) -> some View {
        Text(L10n.conversationAnalyticsHotspots)
            .font(.body.weight(.semibold))
        if hotspots.isEmpty {
            Text(L10n.conversationAnalyticsNoHotspots)
                .font(.callout)
                .foregroundStyle(DahliaDesign.secondaryTextColor)
        } else {
            ForEach(hotspots) { hotspot in
                Label {
                    Text(L10n.conversationAnalyticsHotspotDetail(
                        sourceTitle(hotspot.source),
                        Formatters.elapsedMinutesSeconds(duration: hotspot.start),
                        Formatters.elapsedMinutesSeconds(duration: hotspot.end),
                        hotspot.peakScore.formatted(.number.precision(.fractionLength(1))),
                        driverTitle(hotspot.driver)
                    ))
                } icon: {
                    Image(systemName: "flame.fill")
                        .dahliaFixedSymbol()
                        .foregroundStyle(hotspot.source == .microphone ? .blue : .orange)
                }
                .font(.callout)
            }
        }
    }

    private func sourceTitle(_ source: RecordingAudioSource) -> String {
        source == .microphone ? L10n.conversationAnalyticsYou : L10n.conversationAnalyticsOtherSide
    }

    private func driverTitle(_ driver: MeetingVoiceAnalytics.HotspotDriver) -> String {
        switch driver {
        case .loudness: L10n.conversationAnalyticsLoudnessDriver
        case .pitch: L10n.conversationAnalyticsPitchDriver
        case .both: L10n.conversationAnalyticsBothDriver
        }
    }
}
