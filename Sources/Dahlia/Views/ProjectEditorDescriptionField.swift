import SwiftUI

struct ProjectEditorDescriptionField: View {
    @Binding var description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.projectDescription, systemImage: "text.alignleft")
                .font(.subheadline)
                .bold()

            ZStack(alignment: .topLeading) {
                if description.isEmpty {
                    Text(L10n.projectDescriptionPlaceholder)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 8)
                        .accessibilityHidden(true)
                }

                TextEditor(text: $description)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .accessibilityLabel(L10n.projectDescription)
            }
            .frame(minHeight: 120, maxHeight: 150)
            .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(0.2))
            }
        }
    }
}
