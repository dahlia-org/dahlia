import SwiftUI

struct CodexChatMarkdownBlockView: View {
    let block: CodexChatMarkdownRenderedBlock

    var body: some View {
        switch block {
        case let .paragraph(text):
            renderedText(text)
        case let .heading(level, text):
            renderedText(text)
                .font(headingFont(for: level))
                .fontWeight(.semibold)
        case let .unorderedList(items):
            VStack(alignment: .leading, spacing: 10) {
                ForEach(items.indices, id: \.self) { index in
                    CodexChatMarkdownListRow(marker: "•", text: items[index])
                }
            }
        case let .orderedList(items):
            VStack(alignment: .leading, spacing: 10) {
                ForEach(items.indices, id: \.self) { index in
                    CodexChatMarkdownListRow(marker: items[index].marker, text: items[index].text)
                }
            }
        case let .blockquote(text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(.tertiary)
                    .frame(width: 3)
                renderedText(text)
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

    private func renderedText(_ value: AttributedString) -> some View {
        Text(value)
            .textSelection(.enabled)
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
