import Foundation

enum BatchTranscriptionStallTimeout: Int, CaseIterable, Identifiable, Sendable {
    case oneMinute = 1
    case twoMinutes = 2
    case threeMinutes = 3

    static let defaultValue: Self = .oneMinute

    var id: Int { rawValue }

    var duration: Duration {
        .seconds(rawValue * 60)
    }

    var displayName: String {
        L10n.batchTranscriptionStallTimeoutMinutes(rawValue)
    }

    static func resolved(rawValue: Int) -> Self {
        Self(rawValue: rawValue) ?? defaultValue
    }
}
