import SwiftUI

struct ConversationAnalyticsExpressionCard: View {
    let analytics: MeetingVoiceAnalytics

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.conversationAnalyticsExpression)
                .font(.headline)
            Text(L10n.conversationAnalyticsExpressionDescription)
                .font(.callout)
                .foregroundStyle(DahliaDesign.secondaryTextColor)
            ForEach(analytics.expressions) { expression in
                VStack(alignment: .leading, spacing: 8) {
                    Label(sourceTitle(expression.source), systemImage: sourceIcon(expression.source))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(expression.source == .microphone ? .blue : .orange)
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                        metricRow(
                            title: L10n.conversationAnalyticsPitchVariation,
                            value: expression.pitchVariationSemitones,
                            unit: L10n.conversationAnalyticsSemitones,
                            level: expression.pitchLevel,
                            lowLevelTitle: L10n.conversationAnalyticsExpressionLowPitch,
                            highLevelTitle: L10n.conversationAnalyticsExpressionHighPitch
                        )
                        metricRow(
                            title: L10n.conversationAnalyticsLoudnessVariation,
                            value: expression.loudnessVariationDecibels,
                            unit: "dB",
                            level: expression.loudnessLevel,
                            lowLevelTitle: L10n.conversationAnalyticsExpressionLowLoudness,
                            highLevelTitle: L10n.conversationAnalyticsExpressionHighLoudness
                        )
                    }
                }
                if expression.id != analytics.expressions.last?.id {
                    Divider()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(16)
        .dahliaCardSurface()
    }

    private func metricRow(
        title: String,
        value: Double?,
        unit: String,
        level: MeetingVoiceAnalytics.ExpressionLevel?,
        lowLevelTitle: String,
        highLevelTitle: String
    ) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(DahliaDesign.secondaryTextColor)
            Text(formatted(value, unit: unit))
                .monospacedDigit()
            Text(levelTitle(level, low: lowLevelTitle, high: highLevelTitle))
                .font(.callout.weight(.semibold))
        }
    }

    private func formatted(_ value: Double?, unit: String) -> String {
        guard let value else { return L10n.notAvailable }
        return "\(value.formatted(.number.precision(.fractionLength(1)))) \(unit)"
    }

    private func levelTitle(
        _ level: MeetingVoiceAnalytics.ExpressionLevel?,
        low: String,
        high: String
    ) -> String {
        guard let level else { return L10n.notAvailable }
        return switch level {
        case .low: low
        case .standard:
            L10n.conversationAnalyticsExpressionStandard
        case .high: high
        }
    }

    private func sourceTitle(_ source: RecordingAudioSource) -> String {
        source == .microphone ? L10n.conversationAnalyticsYou : L10n.conversationAnalyticsOtherSide
    }

    private func sourceIcon(_ source: RecordingAudioSource) -> String {
        source == .microphone ? "mic.fill" : "speaker.wave.2.fill"
    }
}
