import SwiftUI

struct ConversationAnalyticsNotesView: View {
    let metrics: MeetingConversationMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.conversationAnalyticsSpeechGapDescription(
                metrics.speechMergeGap.formatted(
                    .number.precision(.fractionLength(0 ... 1))
                )
            ))
            Text(L10n.conversationAnalyticsMonologueGapDescription(
                metrics.monologueMergeGap.formatted(
                    .number.precision(.fractionLength(0 ... 1))
                )
            ))
            if metrics.isTimelineCondensed {
                Label(L10n.conversationAnalyticsCondensedTimelineNote, systemImage: "rectangle.compress.vertical")
            }
            if metrics.usesLegacyTimelineFallback {
                Label(L10n.conversationAnalyticsLegacyTimelineNote, systemImage: "clock.badge.questionmark")
            }
            if metrics.hasUnmeasurableSegments {
                Label(L10n.conversationAnalyticsEstimatedPaceNote, systemImage: "approximately")
            }
            Text(L10n.conversationAnalyticsSourceCaveat)
            Text(L10n.conversationAnalyticsLanguageCaveat)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
