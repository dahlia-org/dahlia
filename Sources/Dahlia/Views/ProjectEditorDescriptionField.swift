import SwiftUI

struct ProjectEditorDescriptionField: View {
    @Binding var description: String
    @FocusState.Binding var isFocused: Bool
    @State private var isHelpPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label(L10n.projectDescription, systemImage: "text.alignleft")
                    .font(.body)
                    .bold()

                Button(
                    L10n.projectDescriptionHelp,
                    systemImage: "info.circle",
                    action: { isHelpPresented.toggle() }
                )
                .labelStyle(.iconOnly)
                .dahliaFixedSymbol()
                .buttonStyle(.borderless)
                .help(L10n.projectDescriptionHelp)
                .popover(isPresented: $isHelpPresented, arrowEdge: .bottom) {
                    Text(L10n.projectDescriptionHelp)
                        .font(.body)
                        .padding(12)
                }
            }

            ZStack(alignment: .topLeading) {
                ProjectDescriptionTextView(text: $description, isFocused: $isFocused)
                    .accessibilityLabel(L10n.projectDescription)

                if description.isEmpty, !isFocused {
                    Text(L10n.projectDescriptionPlaceholder)
                        .font(.body)
                        .foregroundStyle(DahliaDesign.optionalTextColor)
                        .padding(.leading, 8)
                        .padding(.top, 6)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 120, maxHeight: 150)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: .rect(cornerRadius: DahliaDesign.Field.cornerRadius)
            )
            .overlay {
                RoundedRectangle(cornerRadius: DahliaDesign.Field.cornerRadius)
                    .stroke(Color.secondary.opacity(0.2))
            }
        }
    }
}
