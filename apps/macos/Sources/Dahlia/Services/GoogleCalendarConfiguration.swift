import Foundation

enum GoogleCalendarConfiguration {
    private static let clientIDKey = "GOOGLE_CLIENT_ID"
    private static let legacyClientIDKey = "GIDClientID"
    private static let clientSecretKey = "GOOGLE_CLIENT_SECRET"

    static var clientID: String? {
        firstNonEmptyValue([
            infoDictionaryValue(forKey: clientIDKey),
            infoDictionaryValue(forKey: legacyClientIDKey),
            ProcessInfo.processInfo.environment[clientIDKey],
        ])
    }

    static var clientSecret: String? {
        firstNonEmptyValue([
            infoDictionaryValue(forKey: clientSecretKey),
            ProcessInfo.processInfo.environment[clientSecretKey],
        ])
    }

    static var isConfigured: Bool {
        clientID != nil
    }

    private static func infoDictionaryValue(forKey key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }

    private static func nonEmptyValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func firstNonEmptyValue(_ values: [String?]) -> String? {
        values.lazy.compactMap(nonEmptyValue).first
    }
}
