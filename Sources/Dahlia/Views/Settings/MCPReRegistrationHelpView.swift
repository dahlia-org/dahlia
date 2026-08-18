import SwiftUI

struct MCPReRegistrationHelpView: View {
    let removalCommand: String
    let isCopied: Bool
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading) {
            Text(L10n.mcpReRegistrationHelp)
                .dahliaFont(.subsectionTitle, weight: .semibold)

            Text(L10n.mcpReRegistrationHelpDescription)
                .foregroundStyle(.secondary)

            Text(removalCommand)
                .dahliaFont(.body, design: .monospaced)
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
