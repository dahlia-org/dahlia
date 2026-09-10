import Foundation

enum SettingsLanguageOptions {
    static func locales(from enabledLocales: [Locale], including selectedIdentifier: String) -> [Locale] {
        var locales = enabledLocales
        if !locales.contains(where: { $0.identifier == selectedIdentifier }) {
            locales.append(Locale(identifier: selectedIdentifier))
        }
        return locales.sortedByLocalizedName()
    }
}
