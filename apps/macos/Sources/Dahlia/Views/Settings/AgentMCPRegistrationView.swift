import SwiftUI

/// Adds a Unity Gateway MCP service by its fully qualified Unity Catalog name.
struct AgentMCPRegistrationView: View {
    let model: AgentMCPSettingsModel
    let provider: AgentMCPProvider
    @State private var serviceName = ""
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Button(action: onClose) {
                Color.black.opacity(0.16).ignoresSafeArea()
            }
            .buttonStyle(.plain)
            .focusable(false)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.mcpAddService)
                    .font(.dahliaTitle2)
                    .accessibilityAddTraits(.isHeader)
                Text(L10n.unityGatewayHost(provider.host))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField(L10n.mcpServiceName, text: $serviceName, prompt: Text("main.default.notion"))
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                    .onSubmit(add)
                Text(L10n.mcpServiceNameHelp).foregroundStyle(.secondary)
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                HStack {
                    Spacer()
                    Button(L10n.cancel, action: onClose)
                        .buttonStyle(.dahlia())
                        .keyboardShortcut(.cancelAction)
                    Button(L10n.add, action: add)
                        .buttonStyle(.dahlia(.primary))
                        .keyboardShortcut(.defaultAction)
                        .disabled(serviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(24)
            .frame(width: 480)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(.rect(cornerRadius: DahliaDesign.Card.regularCornerRadius))
            .shadow(color: .black.opacity(0.24), radius: 28, y: 12)
        }
        .transition(.identity)
        .onAppear { isFocused = true }
    }

    private func add() {
        do {
            try model.addService(serviceName, to: provider)
            onClose()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
