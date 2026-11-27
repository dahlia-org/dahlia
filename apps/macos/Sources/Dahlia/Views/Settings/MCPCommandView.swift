import SwiftUI

struct MCPCommandView: View {
    let title: String
    let command: String
    let removalCommand: String
    let copiedCommand: String?
    let onCopy: (String) -> Void

    @State private var isReRegistrationHelpPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(command)
                .font(.dahliaBody.monospaced())
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
                .accessibilityLabel(L10n.registrationCommand(title))
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 16) {
                Spacer()

                Button(
                    L10n.mcpReRegistrationHelp,
                    systemImage: "info.circle",
                    action: showReRegistrationHelp
                )
                .buttonStyle(.dahlia())
                .help(L10n.mcpReRegistrationHelp)
                .popover(isPresented: $isReRegistrationHelpPresented, arrowEdge: .bottom) {
                    MCPReRegistrationHelpView(
                        removalCommand: removalCommand,
                        isCopied: copiedCommand == removalCommand,
                        onCopy: copyRemovalCommand
                    )
                }

                Button(
                    copiedCommand == command ? L10n.copied : L10n.copyCommand,
                    systemImage: copiedCommand == command ? "checkmark" : "doc.on.doc",
                    action: copyRegistrationCommand
                )
                .buttonStyle(.dahlia(.primary))
                .font(.dahliaBody.weight(.semibold))
            }
        }
    }

    private func showReRegistrationHelp() {
        isReRegistrationHelpPresented = true
    }

    private func copyRegistrationCommand() {
        onCopy(command)
    }

    private func copyRemovalCommand() {
        onCopy(removalCommand)
    }
}
