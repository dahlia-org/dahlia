struct CodexChatMarkdownParseResult: Equatable {
    let blocks: [CodexChatMarkdownBlock]
    let stablePrefixBlockCount: Int
    let reparseSource: String
}
