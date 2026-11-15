import SwiftUI

struct TranscriptionLanguagePicker: View {
    @ObservedObject private var settings = AppSettings.shared
    let supportedLocales: [Locale]

    var body: some View {
        DahliaMenuPicker(
            title: L10n.transcriptionLanguage,
            description: L10n.appleSpeechSettingsScopeDescription,
            selection: selection,
            options: [SettingsLanguageOptions.automaticTranscription] + SettingsLanguageOptions.locales(
                from: supportedLocales.filter { settings.isLanguageEnabled($0.identifier) },
                including: settings.transcriptionLocale
            ).map(\.identifier)
        ) { identifier in
            identifier == SettingsLanguageOptions.automaticTranscription
                ? L10n.auto
                : Locale(identifier: identifier).localizedString(forIdentifier: identifier) ?? identifier
        }
    }

    private var selection: Binding<String> {
        Binding(
            get: {
                SettingsLanguageOptions.transcriptionSelection(
                    localeIdentifier: settings.transcriptionLocale,
                    detectsAutomatically: settings.automaticTranscriptionLanguageDetectionEnabled
                )
            },
            set: { selection in
                let resolved = SettingsLanguageOptions.resolvedTranscriptionSelection(
                    selection,
                    currentLocaleIdentifier: settings.transcriptionLocale
                )
                settings.transcriptionLocale = resolved.localeIdentifier
                settings.automaticTranscriptionLanguageDetectionEnabled = resolved.detectsAutomatically
            }
        )
    }
}
