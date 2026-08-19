import SwiftUI

struct ProjectCatalogHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Text(L10n.name)
                .frame(maxWidth: 420, alignment: .leading)
            Text(L10n.updated)
                .frame(width: 120, alignment: .leading)
            Color.clear
                .frame(width: 88, height: 1)
            Spacer()
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityHidden(true)
    }
}
