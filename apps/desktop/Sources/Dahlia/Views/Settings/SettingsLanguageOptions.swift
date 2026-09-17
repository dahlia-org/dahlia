import Foundation

enum SettingsLanguageOptions {
    static let automaticTranscription = "__automatic__"

    static func locales(from enabledLocales: [Locale], including selectedIdentifier: String) -> [Locale] {
        var locales = enabledLocales
        if !locales.contains(where: { $0.identifier == selectedIdentifier }) {
            locales.append(Locale(identifier: selectedIdentifier))
        }
        return locales.sortedByLocalizedName()
    }

    static func transcriptionSelection(localeIdentifier: String, detectsAutomatically: Bool) -> String {
        detectsAutomatically ? automaticTranscription : localeIdentifier
    }

    static func resolvedTranscriptionSelection(
        _ selection: String,
        currentLocaleIdentifier: String
    ) -> (localeIdentifier: String, detectsAutomatically: Bool) {
        selection == automaticTranscription
            ? (currentLocaleIdentifier, true)
            : (selection, false)
    }
}
