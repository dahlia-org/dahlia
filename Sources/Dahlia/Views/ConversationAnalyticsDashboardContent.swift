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
                ConversationAnalyticsFlowCard(metrics: metrics)
                ConversationAnalyticsNotesView(metrics: metrics)
            }
            .padding(16)
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
