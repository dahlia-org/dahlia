import SwiftUI

struct ProjectAppearancePicker: View {
    @Binding var appearance: ProjectAppearance

    private let columns = Array(repeating: GridItem(.fixed(44), spacing: 0), count: 6)

    var body: some View {
        VStack(spacing: 8) {
            LazyVGrid(columns: columns, spacing: 0) {
                ForEach(ProjectThemeColor.allCases, id: \.self) { color in
                    colorButton(color)
                }
            }

            Divider()

            LazyVGrid(columns: columns, spacing: 0) {
                ForEach(ProjectIcon.allCases, id: \.self) { icon in
                    iconButton(icon)
                }
            }
        }
        .padding(12)
        .presentationBackground(Color(nsColor: .windowBackgroundColor).opacity(0.96))
    }

    private func colorButton(_ color: ProjectThemeColor) -> some View {
        Button(action: { appearance.color = color }, label: {
            Label(color.localizedName, systemImage: "circle.fill")
                .labelStyle(.iconOnly)
                .font(.title2)
                .foregroundStyle(color.color)
                .frame(width: 44, height: 40)
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
            Label(icon.localizedName, systemImage: icon.systemImageName)
                .labelStyle(.iconOnly)
                .font(.title3)
                .foregroundStyle(appearance.color.color)
                .frame(width: 44, height: 40)
                .background(
                    appearance.icon == icon ? Color.accentColor.opacity(0.14) : .clear,
                    in: .rect(cornerRadius: DahliaDesign.Highlight.regularCornerRadius)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: DahliaDesign.Highlight.regularCornerRadius)
                        .stroke(appearance.icon == icon ? Color.accentColor : .clear)
                }
        })
        .buttonStyle(.plain)
        .accessibilityAddTraits(appearance.icon == icon ? .isSelected : [])
    }
}
