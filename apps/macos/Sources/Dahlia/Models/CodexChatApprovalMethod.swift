import Foundation

/// Whether chat asks before changing Dahlia data. Commands and file changes in the working folder are never asked about.
enum CodexChatApprovalMethod: String, CaseIterable, Identifiable, Sendable {
    case ask
    case autoReview

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: L10n.chatApprovalAsk
        case .autoReview: L10n.chatApprovalAutoReview
        }
    }

    var description: String {
        switch self {
        case .ask: L10n.chatApprovalAskDescription
        case .autoReview: L10n.chatApprovalAutoReviewDescription
        }
    }

    var systemImage: String {
        switch self {
        case .ask: "hand.raised"
        case .autoReview: "checkmark.shield"
        }
    }
}
