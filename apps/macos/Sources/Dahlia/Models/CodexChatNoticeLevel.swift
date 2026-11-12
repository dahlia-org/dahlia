enum CodexChatNoticeLevel: String {
    case info
    case warning
    case error

    var symbol: String {
        switch self {
        case .info: "info.circle"
        case .warning: "exclamationmark.circle"
        case .error: "xmark.circle"
        }
    }
}
