import SwiftUI

struct MCPReRegistrationHelpView: View {
    let removalCommand: String
    let isCopied: Bool
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading) {
            Text(L10n.mcpReRegistrationHelp)
                .font(.headline)

            Text(L10n.mcpReRegistrationHelpDescription)
                .foregroundStyle(.secondary)

            Text(removalCommand)
                .font(.callout.monospaced())
                .textSelection(.enabled)

            Button(
                isCopied ? L10n.copied : L10n.copyRemoveCommand,
                systemImage: isCopied ? "checkmark" : "doc.on.doc",
                action: onCopy
            )
        }
        .padding()
    }
}
