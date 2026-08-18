import SwiftUI

struct MCPJSONSampleView: View {
    let sample: String
    let isCopied: Bool
    let onCopy: (String) -> Void

    var body: some View {
        VStack(alignment: .leading) {
            Text(sample)
                .dahliaFont(.body, design: .monospaced)
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)

            HStack {
                Spacer()
                Button(
                    isCopied ? L10n.copied : L10n.copyMCPJSON,
                    systemImage: isCopied ? "checkmark" : "doc.on.doc",
                    action: copy
                )
            }
        }
    }

    private func copy() {
        onCopy(sample)
    }
}
