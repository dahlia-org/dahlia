import Foundation

enum GoogleCalendarErrorFormatter {
    private static let missingClientSecretPattern = "client_secret is missing"
    private static let keychainErrorPattern = "keychain error"

    static func message(for error: Error) -> String {
        let description = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else {
            return L10n.googleCalendarUnexpectedResponse
        }

        if description.localizedCaseInsensitiveContains(missingClientSecretPattern) {
            return L10n.googleCalendarClientSecretMissingMessage
        }

        if description.localizedCaseInsensitiveContains(keychainErrorPattern) {
            return L10n.googleCalendarKeychainConfigurationMessage
        }

        return description
    }
}
