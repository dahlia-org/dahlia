import Foundation

enum CodexChatMarkdownRenderedBlock: Equatable, Sendable {
    case paragraph(AttributedString)
    case heading(level: Int, text: AttributedString)
    case unorderedList([AttributedString])
    case orderedList([CodexChatMarkdownRenderedOrderedItem])
    case blockquote(AttributedString)
    case table(CodexChatMarkdownRenderedTable)
    case code(language: String?, text: String)
    case divider

}

struct CodexChatMarkdownRenderedTable: Equatable, Sendable {
    let header: [AttributedString]
    let rows: [[AttributedString]]
    let alignments: [CodexChatMarkdownTableAlignment]
}
