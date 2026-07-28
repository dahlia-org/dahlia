import SwiftUI

struct CodexChatReasoningView: View {
    let reasoning: String
    let isStreaming: Bool

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            CodexChatMarkdownView(
                markdown: reasoning,
                isStreaming: isStreaming
            )
            .padding(.top, 8)
        } label: {
            Text(L10n.chatReasoning)
                .foregroundStyle(.secondary)
        }
        .textSelection(.enabled)
    }
}
