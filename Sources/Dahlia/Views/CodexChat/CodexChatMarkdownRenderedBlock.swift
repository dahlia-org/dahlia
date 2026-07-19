import Foundation

enum CodexChatMarkdownRenderedBlock: Sendable {
    case paragraph(AttributedString)
    case heading(level: Int, text: AttributedString)
    case unorderedList([AttributedString])
    case orderedList([CodexChatMarkdownRenderedOrderedItem])
    case blockquote(AttributedString)
    case code(language: String?, text: String)
    case divider
}
