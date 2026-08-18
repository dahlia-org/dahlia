import SwiftUI

struct DahliaWindowHeaderHelp: View {
    let label: String
    let shortcut: String?

    var body: some View {
        HStack(spacing: 8) {
            Text(label)

            if let shortcut {
                Text(shortcut)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.white.opacity(0.12), in: Capsule())
            }
        }
        .dahliaFont(.body)
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.88), in: .rect(cornerRadius: 10))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .fixedSize()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
