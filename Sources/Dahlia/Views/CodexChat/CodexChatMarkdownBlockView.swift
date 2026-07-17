import SwiftUI

struct CodexChatMarkdownBlockView: View {
    let block: CodexChatMarkdownBlock

    var body: some View {
        switch block {
        case let .paragraph(text):
            markdownText(text)
        case let .heading(level, text):
            markdownText(text)
                .font(headingFont(for: level))
                .fontWeight(.semibold)
        case let .unorderedList(items):
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    CodexChatMarkdownListRow(marker: "•", text: item)
                }
            }
        case let .orderedList(items):
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    CodexChatMarkdownListRow(marker: item.marker, text: item.text)
                }
            }
        case let .blockquote(text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(.tertiary)
                    .frame(width: 3)
                markdownText(text)
                    .foregroundStyle(.secondary)
            }
        case let .code(language, text):
            VStack(alignment: .leading, spacing: 6) {
                if let language {
                    Text(language)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ScrollView(.horizontal) {
                    Text(text)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                }
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
        case .divider:
            Divider()
        }
    }

    private func markdownText(_ value: String) -> some View {
        Text(attributedMarkdown(value))
            .textSelection(.enabled)
    }

    private func attributedMarkdown(_ value: String) -> AttributedString {
        (try? AttributedString(
            markdown: value,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(value)
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1: .title
        case 2: .title2
        case 3: .title3
        default: .headline
        }
    }
}
