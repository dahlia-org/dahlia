enum CodexChatPendingInput {
    case manual(String)
    case liveTranscript(String, wasTruncated: Bool)

    var isLiveTranscript: Bool {
        if case .liveTranscript = self {
            return true
        }
        return false
    }

    var manualText: String? {
        guard case let .manual(text) = self else { return nil }
        return text
    }

    var liveTranscript: String? {
        guard case let .liveTranscript(text, _) = self else { return nil }
        return text
    }
}
