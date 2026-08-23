import Foundation

struct AppLanguageSelection: Identifiable, Equatable, Hashable, Sendable {
    let id: String

    func displayName(locale: Locale = .current) -> String {
        let parts = id.split(separator: "-", maxSplits: 1).map(String.init)
        let language = locale.localizedString(forLanguageCode: parts[0]) ?? parts[0]
        guard parts.count == 2 else { return language }
        let script = locale.localizedString(forScriptCode: parts[1]) ?? parts[1]
        return "\(language)（\(script)）"
    }

    static func canonicalIdentifier(from identifier: String) -> String? {
        let locale = Locale(identifier: identifier.replacing("_", with: "-"))
        guard let language = locale.language.languageCode?.identifier.lowercased().nilIfBlank else {
            return nil
        }
        guard language == "zh" else { return language }
        if let script = locale.language.script?.identifier.nilIfBlank {
            return "zh-\(script)"
        }
        return switch locale.region?.identifier.uppercased() {
        case "TW", "HK", "MO": "zh-Hant"
        case "CN", "SG": "zh-Hans"
        default: "zh"
        }
    }

    static func selectedIdentifiers(
        from supportedIdentifiers: [String],
        defaults: UserDefaults
    ) -> [String] {
        let scope = AppLanguageScope(
            rawValue: defaults.string(forKey: AppSettings.appLanguageScopeUserDefaultsKey) ?? ""
        ) ?? .selected
        guard scope == .selected else { return supportedIdentifiers }
        let selected = AppSettings.enabledLanguageIdentifiers(in: defaults)
        return supportedIdentifiers.filter {
            canonicalIdentifier(from: $0).map(selected.contains) == true
        }
    }
}
