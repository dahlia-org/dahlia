import SwiftUI

struct ProjectNameAppearanceField: View {
    @Binding var projectName: String
    @Binding var appearance: ProjectAppearance
    @FocusState.Binding var isProjectNameFocused: Bool
    let isAppearanceEditable: Bool
    let onSubmit: () -> Void
    @State private var isAppearancePickerPresented = false

    var body: some View {
        HStack(spacing: 0) {
            if isAppearanceEditable {
                Button(action: { isAppearancePickerPresented = true }) {
                    Label(L10n.appearance, systemImage: appearance.icon.systemImageName)
                        .labelStyle(.iconOnly)
                        .dahliaFixedSymbol()
                        .foregroundStyle(appearance.color.color)
                        .frame(width: 40, height: 36)
                }
                .buttonStyle(.plain)
                .help(L10n.appearance)
                .popover(isPresented: $isAppearancePickerPresented, arrowEdge: .bottom) {
                    ProjectAppearancePicker(appearance: $appearance)
                }
            } else {
                Label(L10n.appearance, systemImage: appearance.icon.systemImageName)
                    .labelStyle(.iconOnly)
                    .dahliaFixedSymbol()
                    .foregroundStyle(appearance.color.color)
                    .frame(width: 40, height: 36)
            }

            Divider()
                .padding(.vertical, 7)

            TextField(L10n.projectName, text: $projectName)
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .focused($isProjectNameFocused)
                .onSubmit(onSubmit)
        }
        .frame(height: 52)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: .rect(cornerRadius: DahliaDesign.Field.cornerRadius)
        )
        .overlay {
            RoundedRectangle(cornerRadius: DahliaDesign.Field.cornerRadius)
                .stroke(Color.secondary.opacity(0.25))
        }
    }
}
