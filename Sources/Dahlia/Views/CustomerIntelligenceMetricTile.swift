import SwiftUI

struct CustomerIntelligenceMetricTile: View {
    let title: String
    let value: Int
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: systemImage)
                    .foregroundStyle(.secondary)
                Text(value, format: .number)
                    .dahliaFont(.displayTitle, weight: .bold)
                    .monospacedDigit()
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
            .padding()
            .customerIntelligenceCardSurface()
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title): \(value)")
    }
}
