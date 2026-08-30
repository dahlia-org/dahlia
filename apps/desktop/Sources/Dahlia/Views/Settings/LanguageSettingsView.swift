import Speech
import SwiftUI

struct LanguageSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var supportedLocales: [Locale] = []
    @State private var isLoadingLocales = true

    var body: some View {
        Form {
            Section(L10n.display) {
                DahliaMenuPicker(
                    title: L10n.appLanguage,
                    description: L10n.appLanguageDescription,
                    selection: $settings.appLanguage,
                    options: AppLanguage.allCases,
                    label: \.displayName
                )
            }

            Section {
                AppLanguageSelectionRow()
            } header: {
                Text(L10n.appLanguages)
            } footer: {
                Text(L10n.appLanguagesDescription)
            }

            if settings.transcriptionMode == .batch {
                Section(L10n.transcription) {
                    DahliaMenuPicker(
                        title: L10n.transcriptionLanguage,
                        description: L10n.transcriptionLanguageDescription,
                        selection: $settings.transcriptionLocale,
                        options: enabledLocaleOptions(including: settings.transcriptionLocale).map(\.identifier)
                    ) { identifier in
                        Locale(identifier: identifier).localizedString(forIdentifier: identifier) ?? identifier
                    }
                    .disabled(isLoadingLocales)
                }
            }

            Section {
                DahliaMenuPicker(
                    title: L10n.liveSubtitleLanguage,
                    description: settings.transcriptionMode == .realtime
                        ? L10n.liveSubtitleLanguageUsedForRealtimeTranscription
                        : nil,
                    selection: settings.transcriptionMode == .realtime
                        ? $settings.transcriptionLocale
                        : $settings.liveSubtitleLocale,
                    options: enabledLocaleOptions(including: liveSubtitleLocale).map(\.identifier)
                ) { identifier in
                    Locale(identifier: identifier).localizedString(forIdentifier: identifier) ?? identifier
                }
                .disabled(isLoadingLocales)

                Toggle(isOn: $settings.liveSubtitleTranslationEnabled) {
                    Text(L10n.liveSubtitleTranslation)
                    Text(L10n.liveSubtitleTranslationDescription)
                }
                .toggleStyle(.switch)

                DahliaMenuPicker(
                    title: L10n.translationTargetLanguage,
                    description: L10n.liveSubtitleTranslationTargetLanguageDescription,
                    selection: $settings.liveSubtitleTranslationTargetLanguage,
                    options: targetLanguageOptions.map(\.identifier)
                ) { identifier in
                    targetLanguageOptions.first(where: { $0.identifier == identifier })?.displayName ?? identifier
                }
                .disabled(!settings.liveSubtitleTranslationEnabled || isLoadingLocales)
            } header: {
                Text(L10n.liveSubtitles)
            } footer: {
                if !settings.liveSubtitleTranslationEnabled {
                    Text(L10n.enableLiveSubtitleTranslationToChooseLanguage)
                } else if !settings.isLiveSubtitleTranslationEffectivelyEnabled {
                    Text(settings.transcriptionMode == .realtime
                        ? L10n.liveSubtitleTranslationDisabledForMatchingTranscriptionLanguage
                        : L10n.liveSubtitleTranslationDisabledForMatchingLiveSubtitleLanguage)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            supportedLocales = await SpeechSupportedLocales.load().sortedByLocalizedName()
            isLoadingLocales = false
        }
    }

    private var liveSubtitleLocale: String {
        settings.transcriptionMode == .realtime ? settings.transcriptionLocale : settings.liveSubtitleLocale
    }

    private func enabledLocaleOptions(including selectedIdentifier: String) -> [Locale] {
        Self.localeOptions(
            from: supportedLocales.filter { settings.isLanguageEnabled($0.identifier) },
            including: selectedIdentifier
        )
    }

    static func localeOptions(from enabledLocales: [Locale], including selectedIdentifier: String) -> [Locale] {
        var locales = enabledLocales
        if !locales.contains(where: { $0.identifier == selectedIdentifier }) {
            locales.append(Locale(identifier: selectedIdentifier))
        }
        return locales.sortedByLocalizedName()
    }

    private var targetLanguageOptions: [TranscriptTranslationLanguageOption] {
        TranscriptTranslationLanguage.availableTargetLanguages(
            from: supportedLocales,
            including: settings.liveSubtitleTranslationTargetLanguage,
            locale: settings.appLanguage.locale
        )
    }
}
