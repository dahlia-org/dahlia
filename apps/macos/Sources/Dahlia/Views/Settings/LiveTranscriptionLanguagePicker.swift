import SwiftUI

/// The language of the recognizer that runs during recording. Live subtitles and the live transcript draft share that
/// recognizer, so both settings tabs show this one control.
struct LiveTranscriptionLanguagePicker: View {
    @ObservedObject private var settings = AppSettings.shared
    let supportedLocales: [Locale]

    var body: some View {
        DahliaMenuPicker(
            title: L10n.liveTranscriptionLanguage,
            description: L10n.liveTranscriptionLanguageDescription,
            selection: $settings.liveSubtitleLocale,
            options: SettingsLanguageOptions.locales(
                from: supportedLocales.filter { settings.isLanguageEnabled($0.identifier) },
                including: settings.liveSubtitleLocale
            ).map(\.identifier)
        ) { identifier in
            Locale(identifier: identifier).localizedString(forIdentifier: identifier) ?? identifier
        }
    }
}
