import SwiftUI

struct MCPJSONSampleView: View {
    let sample: String
    let isCopied: Bool
    let onCopy: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(sample)
                .font(.dahliaBody.monospaced())
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 16) {
                Spacer()
                Button(
                    isCopied ? L10n.copied : L10n.copyMCPJSON,
                    systemImage: isCopied ? "checkmark" : "doc.on.doc",
                    action: copy
                )
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .font(.dahliaBody.weight(.semibold))
            }
        }
    }

    private func copy() {
        onCopy(sample)
    }
}
