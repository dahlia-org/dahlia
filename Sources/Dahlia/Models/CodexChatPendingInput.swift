enum CodexChatPendingInput {
    case manual(CodexChatManualSubmission)
    case liveTranscript(String, wasTruncated: Bool)

    var isLiveTranscript: Bool {
        if case .liveTranscript = self {
            return true
        }
        return false
    }

    var manualSubmission: CodexChatManualSubmission? {
        guard case let .manual(submission) = self else { return nil }
        return submission
    }

    var liveTranscript: String? {
        guard case let .liveTranscript(text, _) = self else { return nil }
        return text
    }
}
