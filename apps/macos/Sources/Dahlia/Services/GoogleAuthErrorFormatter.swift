import Foundation

enum GoogleAuthErrorFormatter {
    private static let missingClientSecretPattern = "client_secret is missing"
    private static let keychainErrorPattern = "keychain error"

    static func message(for error: Error, defaultMessage: String) -> String {
        let description = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else {
            return defaultMessage
        }

        if description.localizedCaseInsensitiveContains(missingClientSecretPattern) {
            return L10n.googleAccountClientSecretMissingMessage
        }

        if description.localizedCaseInsensitiveContains(keychainErrorPattern) {
            return L10n.googleAccountKeychainConfigurationMessage
        }

        return description
    }
}
