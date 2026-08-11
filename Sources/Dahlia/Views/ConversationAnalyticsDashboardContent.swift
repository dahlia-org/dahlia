import SwiftUI

struct ConversationAnalyticsDashboardContent: View {
    let metrics: MeetingConversationMetrics

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ConversationAnalyticsHeaderView(metrics: metrics)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        ConversationAnalyticsBalanceCard(metrics: metrics)
                        ConversationAnalyticsPaceCard(metrics: metrics)
                    }
                    .frame(minWidth: 674)
                    VStack(spacing: 14) {
                        ConversationAnalyticsBalanceCard(metrics: metrics)
                        ConversationAnalyticsPaceCard(metrics: metrics)
                    }
                }
                ConversationAnalyticsPaceTrendCard(metrics: metrics)
                ConversationAnalyticsFlowCard(metrics: metrics)
                if metrics.voiceAnalytics.hasAvailableSource {
                    ConversationAnalyticsExcitementCard(metrics: metrics)
                    ConversationAnalyticsEnergyTrendCard(metrics: metrics)
                    ConversationAnalyticsExpressionCard(analytics: metrics.voiceAnalytics)
                    ConversationAnalyticsEntrainmentCard(metrics: metrics)
                } else {
                    ConversationAnalyticsVoiceAvailabilityCard(analytics: metrics.voiceAnalytics)
                }
                ConversationAnalyticsNotesView(metrics: metrics)
            }
            .padding(DahliaDesign.tabContentInset)
        }
    }
}

extension View {
    func conversationAnalyticsCard() -> some View {
        background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            }
    }
}
