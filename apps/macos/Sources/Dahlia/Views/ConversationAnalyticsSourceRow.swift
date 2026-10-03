import SwiftUI

struct ConversationAnalyticsSourceRow: View {
    let title: String
    let systemImage: String
    let color: Color
    let primaryValue: String
    let facts: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .dahliaFixedSymbol()
                .foregroundStyle(color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                Text(facts)
                    .font(.callout)
                    .foregroundStyle(DahliaDesign.secondaryTextColor)
            }
            Spacer(minLength: 8)
            Text(primaryValue)
                .bold()
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}
