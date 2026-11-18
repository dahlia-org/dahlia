import SwiftUI

struct CodexChatReasoningView: View {
    let reasoning: String
    let isStreaming: Bool
    let showsActivity: Bool

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { isExpanded.toggle() } label: {
                CodexChatStepRowLabel(symbol: "brain", isExpanded: isExpanded) {
                    // Collapsed, the row previews the thought itself; expanded, the body below shows it in full.
                    Text(isExpanded ? L10n.chatReasoning : preview)
                        .lineLimit(1)
                    if showsActivity {
                        CodexChatThinkingIndicator()
                    }
                }
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .accessibilityHint(isExpanded ? L10n.collapse : L10n.expand)

            if isExpanded {
                CodexChatMarkdownView(
                    markdown: reasoning,
                    isStreaming: isStreaming
                )
                .textSelection(.enabled)
                .padding(.top, 8)
                .padding(.leading, CodexChatDesign.stepContentInset)
            }
        }
    }

    private var preview: String {
        // A single line needs only the start of a long thought.
        String(reasoning.prefix(400)).split(whereSeparator: \.isNewline).joined(separator: " ")
    }
}

/// One work step: a fixed-width symbol, its label, and a trailing disclosure chevron when it expands.
struct CodexChatStepRowLabel<Label: View>: View {
    let symbol: String
    let isExpanded: Bool?
    @ViewBuilder let label: Label

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .frame(width: 16)
                .accessibilityHidden(true)
            label
            Spacer(minLength: 8)
            if let isExpanded {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .accessibilityHidden(true)
            }
        }
        .font(.dahliaSecondary)
        .foregroundStyle(DahliaDesign.secondaryTextColor)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }
}
