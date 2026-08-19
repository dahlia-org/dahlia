import SwiftUI

struct ConversationAnalyticsVoiceAvailabilityCard: View {
    let analytics: MeetingVoiceAnalytics

    var body: some View {
        ContentUnavailableView {
            Label(L10n.conversationAnalyticsVoiceUnavailable, systemImage: "waveform.slash")
        } description: {
            Text(description)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .dahliaCardSurface()
    }

    private var description: String {
        if analytics.sourceStatuses.contains(where: { $0.availability == .insufficientSamples }) {
            L10n.conversationAnalyticsVoiceInsufficientDescription
        } else {
            L10n.conversationAnalyticsVoiceUnavailableDescription
        }
    }
}
