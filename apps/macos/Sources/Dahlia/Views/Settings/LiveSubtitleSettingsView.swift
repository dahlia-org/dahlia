import Speech
import SwiftUI

struct LiveSubtitleSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var supportedLocales: [Locale] = []
    @State private var isLoadingLocales = true

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.liveSubtitleOverlayEnabled) {
                    Text(L10n.liveSubtitles)
                    Text(L10n.liveSubtitleOverlayToggleDescription)
                }
                .toggleStyle(.switch)

                LiveTranscriptionLanguagePicker(supportedLocales: supportedLocales)
                    .disabled(isLoadingLocales)
            } footer: {
                Text(L10n.liveSubtitleOverlayDescription)
            }

            Section {
                Toggle(isOn: $settings.includesMicrophoneInLiveSubtitles) {
                    Text(L10n.includeMicrophone)
                    Text(L10n.liveSubtitleMicrophoneDescription)
                }
                .toggleStyle(.switch)
                .disabled(!settings.liveSubtitleOverlayEnabled)

                Picker(selection: $settings.liveSubtitleOverlaySegmentCount) {
                    ForEach(1 ..< 6, id: \.self) { count in
                        Text("\(count)").font(.dahliaBody).tag(count)
                    }
                } label: {
                    Text(L10n.liveSubtitleOverlaySegmentCount)
                    Text(L10n.liveSubtitleOverlaySegmentCountDescription)
                }
                .pickerStyle(.menu)
                .disabled(!settings.liveSubtitleOverlayEnabled)
            } header: {
                Text(L10n.liveSubtitleOverlay)
                    .font(.dahliaSectionHeader)
            } footer: {
                if !settings.liveSubtitleOverlayEnabled {
                    Text(L10n.enableLiveSubtitlesToConfigure)
                }
            }

            Section {
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
                Text(L10n.liveSubtitleTranslation)
                    .font(.dahliaSectionHeader)
            } footer: {
                if !settings.liveSubtitleTranslationEnabled {
                    Text(L10n.enableLiveSubtitleTranslationToChooseLanguage)
                } else if !settings.isLiveSubtitleTranslationEffectivelyEnabled {
                    Text(L10n.liveSubtitleTranslationDisabledForMatchingLiveTranscriptionLanguage)
                }
            }
        }
        .formStyle(.grouped)
        .font(.dahliaBody)
        .task {
            supportedLocales = await SpeechSupportedLocales.load().sortedByLocalizedName()
            isLoadingLocales = false
        }
    }

    private var targetLanguageOptions: [TranscriptTranslationLanguageOption] {
        TranscriptTranslationLanguage.availableTargetLanguages(
            from: supportedLocales,
            including: settings.liveSubtitleTranslationTargetLanguage,
            locale: settings.appLanguage.locale
        )
    }
}
