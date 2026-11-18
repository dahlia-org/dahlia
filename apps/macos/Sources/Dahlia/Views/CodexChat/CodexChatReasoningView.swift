import SwiftUI

struct CodexChatReasoningView: View {
    let reasoning: String
    let isStreaming: Bool
    let showsActivity: Bool

    @State private var isExpanded = false
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { isExpanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .accessibilityHidden(true)
                    Text(L10n.chatReasoning)
                    if showsActivity {
                        CodexChatThinkingIndicator()
                    }
                }
                .font(.dahliaSecondary)
                .foregroundStyle(DahliaDesign.secondaryTextColor)
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
                .background(isHovered ? DahliaDesign.contentHighlightColor : .clear, in: .rect(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .onHover { isHovered = $0 }
            .accessibilityHint(isExpanded ? L10n.collapse : L10n.expand)

            if isExpanded {
                CodexChatMarkdownView(
                    markdown: reasoning,
                    isStreaming: isStreaming
                )
                .textSelection(.enabled)
                .padding(.top, 8)
            }
        }
    }
}
