import SwiftUI

struct CodexChatConfigurationPanel: View {
    @Bindable var session: CodexChatSessionModel
    @Binding var showsModels: Bool
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            if showsModels {
                CodexChatModelPickerPanel(
                    session: session,
                    onSelect: onDismiss
                )

                Divider()
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.responsePerformance)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 2)

                ForEach(session.effortOptions) { effort in
                    CodexChatConfigurationRow(
                        title: effort.displayName,
                        isSelected: effort.reasoningEffort == session.selectedEffort,
                        action: { selectEffort(effort.reasoningEffort) }
                    )
                }

                Divider()
                    .padding(.vertical, 4)

                CodexChatConfigurationRow(
                    title: selectedModelName,
                    isSelected: false,
                    trailingSystemImage: "chevron.right",
                    action: toggleModels
                )
            }
            .padding(10)
            .frame(
                width: CodexChatDesign.configurationPanelWidth,
                height: CodexChatDesign.configurationPanelHeight,
                alignment: .topLeading
            )
        }
        .fixedSize()
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(.separator.opacity(0.65), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
    }

    private var selectedModelName: String {
        session.models.first(where: { $0.model == session.selectedModelID })?.displayName
            ?? session.selectedModelID
    }

    private func selectEffort(_ effort: String) {
        session.selectEffort(effort)
        onDismiss()
    }

    private func toggleModels() {
        showsModels.toggle()
    }
}
