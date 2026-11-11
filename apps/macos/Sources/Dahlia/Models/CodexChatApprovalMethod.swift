import Foundation

/// Whether chat asks before changing Dahlia data. Commands and file changes in the working folder are never asked about.
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
}
