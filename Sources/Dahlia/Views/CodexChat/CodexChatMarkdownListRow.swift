import SwiftUI

struct CodexChatMarkdownListRow: View {
    let marker: String
    let text: AttributedString

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker)
                .frame(minWidth: 14, alignment: .trailing)
            Text(text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
