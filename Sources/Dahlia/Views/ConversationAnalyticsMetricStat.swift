import SwiftUI

struct ConversationAnalyticsMetricStat: View {
    let title: String
    let value: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .dahliaFont(.secondary)
                .foregroundStyle(.secondary)
            Text(value)
                .dahliaFont(.subsectionTitle, weight: .semibold)
                .monospacedDigit()
            if let detail {
                Text(detail)
                    .dahliaFont(.secondary)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }
}
