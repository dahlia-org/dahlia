import SwiftUI

struct AppearanceSelectionView: View {
    @Binding var selection: AppAppearance
    @State private var hovered: AppAppearance?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(AppAppearance.allCases) { appearance in
                Button {
                    selection = appearance
                } label: {
                    VStack(spacing: 8) {
                        preview(appearance)
                            .frame(height: 90)
                            .clipShape(.rect(cornerRadius: 6))
                            .accessibilityHidden(true)
                        Text(appearance.displayName)
                            .font(.dahliaBody)
                            .frame(maxWidth: .infinity)
                    }
                    .padding(8)
                    .background(
                        selection == appearance ? Color.accentColor.opacity(0.08) : .clear,
                        in: .rect(cornerRadius: 10)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(
                                selection == appearance ? Color.accentColor : .secondary.opacity(hovered == appearance ? 0.6 : 0.2),
                                lineWidth: selection == appearance ? 2 : 1
                            )
                    }
                    .contentShape(.rect(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? appearance : nil }
                .accessibilityLabel(appearance.displayName)
                .accessibilityAddTraits(selection == appearance ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.appearance)
    }

    private func preview(_ appearance: AppAppearance) -> some View {
        GeometryReader { geometry in
            ZStack {
                miniature(isDark: appearance == .dark)
                if appearance == .system {
                    miniature(isDark: true)
                        .mask(alignment: .trailing) {
                            Rectangle().frame(width: geometry.size.width / 2)
                        }
                }
            }
        }
    }

    private func miniature(isDark: Bool) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 6) {
                Capsule().fill(Color.accentColor.opacity(0.5))
                Capsule().fill(.gray.opacity(0.2))
                Capsule().fill(.gray.opacity(0.2))
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(width: 42)
            .background(isDark ? Color(white: 0.13) : Color(white: 0.94))

            VStack(alignment: .leading, spacing: 6) {
                Capsule().fill(.gray.opacity(0.4)).frame(height: 5)
                Capsule().fill(.gray.opacity(0.2)).frame(height: 5).padding(.trailing, 12)
                Spacer(minLength: 0)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(0.2))
                    .frame(height: 20)
            }
            .padding(10)
        }
        .background(isDark ? Color(white: 0.08) : .white)
    }
}
