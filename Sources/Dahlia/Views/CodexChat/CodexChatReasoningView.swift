import SwiftUI

struct CodexChatReasoningView: View {
    let reasoning: String
    let isStreaming: Bool
    let showsActivity: Bool

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            CodexChatMarkdownView(
                markdown: reasoning,
                isStreaming: isStreaming
            )
            .padding(.top, 8)
        } label: {
            HStack {
                Text(L10n.chatReasoning)
                if showsActivity {
                    CodexChatThinkingIndicator()
                }
            }
            .foregroundStyle(.secondary)
        }
        .textSelection(.enabled)
    }
}
