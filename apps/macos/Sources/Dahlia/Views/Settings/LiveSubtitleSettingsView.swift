import SwiftUI

struct LiveSubtitleSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @Bindable private var workspaceSettings = WorkspaceAISettingsModel.shared
    let supportedLocales: [Locale]
    let isLoadingLocales: Bool

    var body: some View {
        if let error = workspaceSettings.errorMessage {
            Section { SettingsStatusMessage(text: error, systemImage: "exclamationmark.triangle", tint: .orange) }
        }
        if settings.currentWorkspace != nil {
            Section {
                Toggle(L10n.liveTranscriptDraft, isOn: $workspaceSettings.generationSettings.liveTranscriptDraft)
                    .toggleStyle(.switch)
            } header: {
                Text(L10n.liveTranscriptDraftSectionTitle)
                    .font(.dahliaSectionHeader)
            }
        }

        Section {
            Toggle(isOn: $settings.liveSubtitleOverlayEnabled) {
                Text(L10n.liveSubtitles)
                Text(L10n.liveSubtitleOverlayToggleDescription)
            }
            .toggleStyle(.switch)

            LiveTranscriptionLanguagePicker(supportedLocales: supportedLocales)
                .disabled(isLoadingLocales)

            Toggle(isOn: $settings.includesMicrophoneInLiveSubtitles) {
                Text(L10n.includeMicrophone)
                Text(L10n.liveSubtitleMicrophoneDescription)
            }
            .toggleStyle(.switch)

            Picker(selection: $settings.liveSubtitleOverlaySegmentCount) {
                ForEach(1 ..< 6, id: \.self) { count in
                    Text("\(count)").font(.dahliaBody).tag(count)
                }
            } label: {
                Text(L10n.liveSubtitleOverlaySegmentCount)
                Text(L10n.liveSubtitleOverlaySegmentCountDescription)
            }
            .pickerStyle(.menu)
        } header: {
            Text(L10n.liveSubtitles)
                .font(.dahliaSectionHeader)
        } footer: {
            Text(L10n.liveSubtitleOverlayDescription)
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

    private var targetLanguageOptions: [TranscriptTranslationLanguageOption] {
        TranscriptTranslationLanguage.availableTargetLanguages(
            from: supportedLocales,
            including: settings.liveSubtitleTranslationTargetLanguage,
            locale: settings.appLanguage.locale
        )
    }
}
