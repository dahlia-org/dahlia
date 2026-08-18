import SwiftUI

struct ConversationAnalyticsHeaderView: View {
    let metrics: MeetingConversationMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(L10n.conversationAnalytics)
                    .dahliaFont(.displayTitle, weight: .bold)
                Text(L10n.conversationAnalyticsBeta)
                    .dahliaFont(.secondary, weight: .bold)
                    .foregroundStyle(.purple)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.purple.opacity(0.12), in: .capsule)
            }
            if let share = metrics.speechShare(for: .microphone) {
                Text(
                    L10n.conversationAnalyticsSpeakingShareSummary(
                        share.formatted(.percent.precision(.fractionLength(0)))
                    )
                )
                .dahliaFont(.subsectionTitle, weight: .semibold)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
