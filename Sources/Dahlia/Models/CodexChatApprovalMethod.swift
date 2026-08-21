import Foundation

enum CodexChatApprovalMethod: String, CaseIterable, Identifiable, Sendable {
    case ask
    case autoReview
    case fullAccess

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: L10n.chatApprovalAsk
        case .autoReview: L10n.chatApprovalAutoReview
        case .fullAccess: L10n.chatApprovalFullAccess
        }
    }

    var description: String {
        switch self {
        case .ask: L10n.chatApprovalAskDescription
        case .autoReview: L10n.chatApprovalAutoReviewDescription
        case .fullAccess: L10n.chatApprovalFullAccessDescription
        }
    }

    var systemImage: String {
        switch self {
        case .ask: "hand.raised"
        case .autoReview: "checkmark.shield"
        case .fullAccess: "exclamationmark.shield"
        }
    }

    var approvalPolicy: JSONValue {
        .string(self == .fullAccess ? "never" : "on-request")
    }

    var approvalsReviewer: JSONValue {
        .string(self == .autoReview ? "auto_review" : "user")
    }

    var sandboxPolicy: JSONValue {
        switch self {
        case .ask, .autoReview:
            .object([
                "networkAccess": .bool(false),
                "type": .string("workspaceWrite"),
            ])
        case .fullAccess:
            .object(["type": .string("dangerFullAccess")])
        }
    }

    static func defaultMethod(for provider: AIAccountProvider?) -> Self {
        provider == .chatGPTSubscription ? .autoReview : .ask
    }

    func availableMethod(for provider: AIAccountProvider?) -> Self {
        self == .autoReview && provider != .chatGPTSubscription ? .ask : self
    }

    static func restored(
        approvalPolicy: JSONValue?,
        approvalsReviewer: JSONValue?,
        sandbox: JSONValue?
    ) -> Self? {
        let sandboxType = sandbox?.objectValue?["type"]?.stringValue ?? sandbox?.stringValue
        if approvalPolicy?.stringValue == "never", sandboxType == "dangerFullAccess" {
            return .fullAccess
        }
        guard approvalPolicy?.stringValue == "on-request",
              sandboxType == "workspaceWrite" || sandboxType == "workspace-write" else { return nil }
        return approvalsReviewer?.stringValue == "auto_review" ? .autoReview : .ask
    }
}
