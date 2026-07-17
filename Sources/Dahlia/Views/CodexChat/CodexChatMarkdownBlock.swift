enum CodexChatMarkdownBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case unorderedList([String])
    case orderedList([CodexChatMarkdownOrderedItem])
    case blockquote(String)
    case code(language: String?, text: String)
    case divider
}
