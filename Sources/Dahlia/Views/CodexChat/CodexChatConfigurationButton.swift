import SwiftUI

struct CodexChatConfigurationButton: View {
    @Bindable var session: CodexChatSessionModel
    let externalPresentation: Binding<Bool>?

    @State private var isHovering = false
    @State private var isPresented = false
    @State private var showsModels = false

    var body: some View {
        Button(configurationLabel, action: showConfiguration)
            .buttonStyle(.plain)
            .dahliaFont(.body)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: CodexChatDesign.controlSize)
            .background(
                isHovering || presentationIsActive ? DahliaDesign.hoverHighlightColor : .clear,
                in: Capsule()
            )
            .onHover { isHovering = $0 }
            .help(L10n.model)
            .overlay(alignment: .bottomTrailing) {
                if externalPresentation == nil, isPresented {
                    CodexChatConfigurationPanel(
                        session: session,
                        showsModels: $showsModels,
                        onDismiss: dismissConfiguration
                    )
                    .codexChatDismissOnOutsideClick(perform: dismissConfiguration)
                    .offset(
                        x: CodexChatDesign.controlSize,
                        y: -(CodexChatDesign.controlSize + CodexChatDesign.floatingPanelSpacing)
                    )
                    .zIndex(1)
                }
            }
            .onExitCommand(perform: dismissConfiguration)
            .zIndex(presentationIsActive ? 1 : 0)
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

    private var presentationIsActive: Bool {
        externalPresentation?.wrappedValue ?? isPresented
    }

    private func showConfiguration() {
        if let externalPresentation {
            externalPresentation.wrappedValue.toggle()
        } else if isPresented {
            dismissConfiguration()
        } else {
            isPresented = true
        }
    }

    private func dismissConfiguration() {
        externalPresentation?.wrappedValue = false
        isPresented = false
        showsModels = false
    }
}
