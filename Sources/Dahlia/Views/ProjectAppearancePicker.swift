import SwiftUI

struct ProjectAppearancePicker: View {
    @Binding var appearance: ProjectAppearance

    private let columns = Array(repeating: GridItem(.fixed(36), spacing: 8), count: 6)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.projectThemeColor)
                    .font(.headline)

                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(ProjectThemeColor.allCases, id: \.self) { color in
                        colorButton(color)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.projectIcon)
                    .font(.headline)

                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(ProjectIcon.allCases, id: \.self) { icon in
                        iconButton(icon)
                    }
                }
            }
        }
        .padding()
    }

    private func colorButton(_ color: ProjectThemeColor) -> some View {
        Button(action: { appearance.color = color }, label: {
            Label(color.localizedName, systemImage: "circle.fill")
                .labelStyle(.iconOnly)
                .font(.title3)
                .foregroundStyle(color.color)
                .frame(width: 36, height: 32)
                .overlay {
                    Circle()
                        .stroke(appearance.color == color ? Color.accentColor : .clear, lineWidth: 2)
                }
                .overlay(alignment: .bottomTrailing) {
                    if appearance.color == color {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.accentColor, Color(nsColor: .windowBackgroundColor))
                    }
                }
        })
        .buttonStyle(.plain)
        .accessibilityAddTraits(appearance.color == color ? .isSelected : [])
    }

    private func iconButton(_ icon: ProjectIcon) -> some View {
        Button(action: { appearance.icon = icon }, label: {
            Label(icon.localizedName, systemImage: icon.rawValue)
                .labelStyle(.iconOnly)
                .foregroundStyle(appearance.color.color)
                .frame(width: 36, height: 32)
                .background(
                    appearance.icon == icon ? Color.accentColor.opacity(0.14) : .clear,
                    in: .rect(cornerRadius: 8)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(appearance.icon == icon ? Color.accentColor : .clear)
                }
        })
        .buttonStyle(.plain)
        .accessibilityAddTraits(appearance.icon == icon ? .isSelected : [])
    }
}
