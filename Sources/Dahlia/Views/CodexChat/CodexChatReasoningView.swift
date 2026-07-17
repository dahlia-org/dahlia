import SwiftUI

struct CodexChatReasoningView: View {
    let reasoning: String
    let isStreaming: Bool

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Group {
                if isStreaming {
                    Text(reasoning)
                } else {
                    CodexChatMarkdownView(markdown: reasoning)
                }
            }
            .padding(.top, 8)
        } label: {
            Text(L10n.chatReasoning)
                .foregroundStyle(.secondary)
        }
        .textSelection(.enabled)
    }
}
