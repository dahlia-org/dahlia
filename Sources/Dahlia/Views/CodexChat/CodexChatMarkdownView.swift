import SwiftUI

struct CodexChatMarkdownView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                if segment.isCode {
                    ScrollView(.horizontal) {
                        Text(segment.text)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(10)
                    }
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                } else if !segment.text.isEmpty {
                    Text(attributedMarkdown(segment.text))
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var segments: [(text: String, isCode: Bool)] {
        markdown.components(separatedBy: "```").enumerated().map { index, text in
            let isCode = index.isMultiple(of: 2) == false
            let cleaned = isCode ? text.replacing(/^\w*\n/, with: "") : text
            return (cleaned.trimmingCharacters(in: isCode ? .newlines : []), isCode)
        }
    }

    private func attributedMarkdown(_ value: String) -> AttributedString {
        (try? AttributedString(
            markdown: value,
            options: .init(interpretedSyntax: .full)
        )) ?? AttributedString(value)
    }
}
