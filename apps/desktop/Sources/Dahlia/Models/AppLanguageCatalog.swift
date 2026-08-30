import Foundation
import WhisperKit

enum AppLanguageCatalog {
    static func load() async -> [AppLanguageSelection] {
        async let speechLocales = SpeechSupportedLocales.load()
        let identifiers = await speechLocales.map(\.identifier)
            + Array(Constants.languageCodes)
        return Set(identifiers.compactMap(AppLanguageSelection.canonicalIdentifier))
            .map(AppLanguageSelection.init(id:))
            .sorted {
                $0.displayName().compare($1.displayName(), locale: .current) == .orderedAscending
            }
    }
}
