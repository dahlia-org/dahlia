import SwiftUI

struct CodexChatConfigurationPanel: View {
    @Bindable var session: CodexChatSessionModel
    @Binding var showsModels: Bool

    var body: some View {
        HStack(spacing: 0) {
            if showsModels {
                // Choosing a model or level keeps the panel open; a click outside or Escape closes it.
                CodexChatModelPickerPanel(session: session, height: panelHeight)

                Divider()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: CodexChatDesign.configurationRowSpacing) {
                    Text(L10n.responsePerformance)
                        .font(.dahliaBody)
                        .foregroundStyle(DahliaDesign.optionalTextColor)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 2)

                    ForEach(effortLevels) { effort in
                        CodexChatConfigurationRow(
                            title: effort.displayName,
                            isSelected: effort.reasoningEffort == session.selectedEffort,
                            isEnabled: supportedEfforts.contains(effort.reasoningEffort),
                            action: { session.selectEffort(effort.reasoningEffort) }
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
            }
            .scrollIndicators(.hidden)
            .frame(
                width: CodexChatDesign.configurationPanelWidth,
                height: panelHeight,
                alignment: .topLeading
            )
        }
        .frame(height: panelHeight)
        .codexChatPanelStyle()
    }

    private var supportedEfforts: Set<String> {
        Set(session.effortOptions.map(\.reasoningEffort))
    }

    /// Pi's levels, then any other level the model offers.
    private var effortLevels: [CodexReasoningEffortOption] {
        CodexChatDesign.reasoningEfforts.map { CodexReasoningEffortOption(reasoningEffort: $0, description: "") }
            + session.effortOptions.filter { !CodexChatDesign.reasoningEfforts.contains($0.reasoningEffort) }
    }

    private var panelHeight: CGFloat {
        CodexChatDesign.configurationPanelHeight(effortCount: effortLevels.count)
    }

    private var selectedModelName: String {
        session.models.first(where: { $0.model == session.selectedModelID })?.displayName
            ?? session.selectedModelID
    }

    private func toggleModels() {
        showsModels.toggle()
    }
}
