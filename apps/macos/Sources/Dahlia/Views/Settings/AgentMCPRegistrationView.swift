import SwiftUI

// shortcut: remote MCP servers are not implemented yet; the modal says so until they are.
/// Adds a remote MCP server by URL. Unity Gateway MCPs are turned on in the MCPs tab instead.
struct AgentMCPRegistrationView: View {
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
                Text(L10n.addRemoteMCPServerTitle)
                    .font(.title2)
                    .accessibilityAddTraits(.isHeader)
                Text(L10n.mcpKindRemoteComingSoon)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button(L10n.close, action: onClose)
                        .buttonStyle(.dahlia())
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(24)
            .frame(width: 480)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(.rect(cornerRadius: DahliaDesign.Card.regularCornerRadius))
            .shadow(color: .black.opacity(0.24), radius: 28, y: 12)
        }
        .transition(.identity)
    }
}
