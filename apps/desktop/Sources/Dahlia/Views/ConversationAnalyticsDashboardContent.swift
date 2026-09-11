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
                ConversationAnalyticsNotesView(metrics: metrics)
            }
            .padding(DahliaDesign.tabContentInset)
        }
    }
}
