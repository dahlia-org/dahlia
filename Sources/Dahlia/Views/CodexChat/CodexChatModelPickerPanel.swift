import SwiftUI

struct CodexChatModelPickerPanel: View {
    @Bindable var session: CodexChatSessionModel
    let onSelect: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                Text(L10n.model)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 2)

                ForEach(session.models) { model in
                    CodexChatConfigurationRow(
                        title: model.displayName,
                        isSelected: model.model == session.selectedModelID,
                        action: { selectModel(model.model) }
                    )
                }
            }
            .padding(10)
        }
        .scrollIndicators(.hidden)
        .frame(
            width: CodexChatDesign.modelPanelWidth,
            height: CodexChatDesign.configurationPanelHeight
        )
    }

    private func selectModel(_ modelID: String) {
        session.selectModel(modelID)
        onSelect()
    }
}
