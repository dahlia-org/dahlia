import SwiftUI

struct CodexChatConfigurationButton: View {
    @Bindable var session: CodexChatSessionModel

    @State private var isHovering = false
    @State private var isPresented = false
    @State private var showsModels = false

    var body: some View {
        Button(configurationLabel, action: showConfiguration)
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: CodexChatDesign.controlSize)
            .background(
                isHovering || isPresented ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                in: Capsule()
            )
            .onHover { isHovering = $0 }
            .help(L10n.model)
            .overlay(alignment: .bottomTrailing) {
                if isPresented {
                    CodexChatConfigurationPanel(
                        session: session,
                        showsModels: $showsModels,
                        onDismiss: dismissConfiguration
                    )
                    .offset(
                        x: CodexChatDesign.controlSize,
                        y: -(CodexChatDesign.controlSize + 8)
                    )
                    .zIndex(1)
                }
            }
            .onExitCommand(perform: dismissConfiguration)
            .zIndex(isPresented ? 1 : 0)
    }

    private var configurationLabel: String {
        let modelName = session.models.first(where: { $0.model == session.selectedModelID })?.displayName
            ?? session.selectedModelID
        let effortName = session.effortOptions.first(where: {
            $0.reasoningEffort == session.selectedEffort
        })?.displayName ?? session.selectedEffort
        return [modelName, effortName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func showConfiguration() {
        if isPresented {
            dismissConfiguration()
        } else {
            isPresented = true
        }
    }

    private func dismissConfiguration() {
        isPresented = false
        showsModels = false
    }
}
