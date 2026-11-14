import SwiftUI

struct MCPJSONSampleView: View {
    let sample: String
    let isCopied: Bool
    let onCopy: (String) -> Void

    var body: some View {
        VStack(alignment: .leading) {
            DisclosureGroup(L10n.mcpShowJSON) {
                Text(sample)
                    .font(.dahliaBody.monospaced())
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
            }

            HStack {
                Spacer()
                Button(
                    isCopied ? L10n.copied : L10n.copyMCPJSON,
                    systemImage: isCopied ? "checkmark" : "doc.on.doc",
                    action: copy
                )
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func copy() {
        onCopy(sample)
    }
}
