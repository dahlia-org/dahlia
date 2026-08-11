enum CodexChatMarkdownBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case unorderedList([String])
    case orderedList([CodexChatMarkdownOrderedItem])
    case blockquote(String)
    case table(CodexChatMarkdownTable)
    case code(language: String?, text: String)
    case divider
}

struct CodexChatMarkdownTable: Equatable {
    let header: [String]
    let rows: [[String]]
    let alignments: [CodexChatMarkdownTableAlignment]
}

enum CodexChatMarkdownTableAlignment: Equatable, Sendable {
    case left
    case center
    case right
}
