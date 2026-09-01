import SwiftUI

struct CodexChatConfigurationOverlay: View {
    @Bindable var session: CodexChatSessionModel
    @Binding var isPresented: Bool

    @State private var showsModels = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if isPresented {
                CodexChatConfigurationPanel(
                    session: session,
                    showsModels: $showsModels,
                    onDismiss: dismiss
                )
                .codexChatDismissOnOutsideClick(perform: dismiss)
                .padding(.trailing, 16)
                .padding(.bottom, CodexChatDesign.controlSize + 28)
                .onExitCommand(perform: dismiss)
                .zIndex(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .onChange(of: isPresented) { _, isPresented in
            if !isPresented {
                showsModels = false
            }
        }
    }

    private func dismiss() {
        isPresented = false
        showsModels = false
    }
}
