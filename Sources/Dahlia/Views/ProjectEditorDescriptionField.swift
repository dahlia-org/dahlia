import SwiftUI

struct ProjectEditorDescriptionField: View {
    @Binding var description: String
    @FocusState.Binding var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.projectDescription, systemImage: "text.alignleft")
                .font(.body)
                .bold()

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
