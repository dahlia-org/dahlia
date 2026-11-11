import SwiftUI

struct ConversationAnalyticsMetricStat: View {
    let title: String
    let value: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.dahliaSecondary)
                .foregroundStyle(DahliaDesign.secondaryTextColor)
            Text(value)
                .font(.dahliaHeadline)
                .monospacedDigit()
            if let detail {
                Text(detail)
                    .font(.dahliaSecondary)
                    .foregroundStyle(DahliaDesign.secondaryTextColor)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }
}
