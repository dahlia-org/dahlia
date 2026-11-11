import Foundation

/// The latest tool event, shown only while its turn is active. Arguments and output stay out of this projection.
struct CodexChatToolActivity: Equatable {
    enum Status: Equatable {
        case running, succeeded, failed, inaccessible
    }

    let name: String
    let status: Status

    var text: String {
        switch status {
        case .running: L10n.chatToolRunning(name)
        case .succeeded: L10n.chatToolSucceeded(name)
        case .failed: L10n.chatToolFailed(name)
        case .inaccessible: L10n.chatToolInaccessible(name)
        }
    }

    var symbol: String {
        switch status {
        case .running: "gearshape"
        case .succeeded: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .inaccessible: "lock.circle"
        }
    }
}
