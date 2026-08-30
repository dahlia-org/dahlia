struct CodexChatMCPToolCall: Equatable, Sendable {
    let server: String?
    let tool: String?
    let arguments: String?
    let isTruncated: Bool
}
