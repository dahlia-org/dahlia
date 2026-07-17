import Speech
import SwiftUI

/// 設定画面「文字起こし」タブ。認識言語の表示フィルタを管理する。
struct TranscriptionSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @AppStorage(AppSettings.generateSummaryAfterBatchTranscriptionUserDefaultsKey)
    private var generateSummaryAfterBatchTranscription = false
    @AppStorage(AppSettings.exportBatchSummaryToVaultUserDefaultsKey)
    private var exportBatchSummaryToVault = true
    @AppStorage(AppSettings.exportBatchSummaryToGoogleDocsUserDefaultsKey)
    private var exportBatchSummaryToGoogleDocs = false
    @State private var supportedLocales: [Locale] = []
    @State private var isLoadingLocales = false
    @State private var localeSearchText = ""

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.isRealtimeTranscriptionEnabled) {
                    Text(L10n.enableRealtimeTranscription)
                    Text(L10n.realtimeTranscriptionDescription)
                }
                .toggleStyle(.switch)

                if !settings.isRealtimeTranscriptionEnabled {
                    Toggle(isOn: $settings.retainAudioAfterBatchTranscription) {
                        Text(L10n.retainBatchAudio)
                        Text(L10n.retainBatchAudioDescription)
                    }
                    .toggleStyle(.switch)

                    Toggle(isOn: $generateSummaryAfterBatchTranscription) {
                        Text(L10n.generateSummaryAfterBatchTranscription)
                        Text(L10n.generateSummaryAfterBatchTranscriptionDescription)
                    }
                    .toggleStyle(.switch)

                    Toggle(isOn: $exportBatchSummaryToVault) {
                        Text(L10n.exportBatchSummaryToVault)
                        Text(L10n.exportBatchSummaryToVaultDescription)
                    }
                    .toggleStyle(.switch)
                    .disabled(!generateSummaryAfterBatchTranscription)

                    Toggle(isOn: $exportBatchSummaryToGoogleDocs) {
                        Text(L10n.exportBatchSummaryToGoogleDocs)
                        Text(L10n.exportBatchSummaryToGoogleDocsDescription)
                    }
                    .toggleStyle(.switch)
                    .disabled(!generateSummaryAfterBatchTranscription)
                }
            } header: {
                Text(L10n.transcriptionMethod)
            } footer: {
                if !settings.isRealtimeTranscriptionEnabled {
                    Text(L10n.batchTranscriptionDescription)
                }
            }

            Section {
                Toggle(isOn: $settings.transcriptTranslationEnabled) {
                    Text(L10n.transcriptTranslation)
                    Text(L10n.transcriptTranslationDescription)
                }
                .toggleStyle(.switch)

                Picker(selection: $settings.transcriptTranslationTargetLanguage) {
                    ForEach(targetLanguageOptions) { option in
                        Text(option.displayName).tag(option.identifier)
                    }
                } label: {
                    Text(L10n.translationTargetLanguage)
                    Text(L10n.translationTargetLanguageDescription)
                }
                .pickerStyle(.menu)
                .disabled(!settings.transcriptTranslationEnabled)
            } header: {
                Text(L10n.transcriptTranslation)
            } footer: {
                if !settings.transcriptTranslationEnabled {
                    Text(L10n.enableTranscriptTranslationToChooseLanguage)
                } else if !settings.isTranscriptTranslationEffectivelyEnabled {
                    Text(L10n.translationDisabledForMatchingLanguage)
                }
            }

            Section {
                Toggle(isOn: $settings.liveSubtitleOverlayEnabled) {
                    Text(L10n.liveSubtitles)
                    Text(L10n.liveSubtitleOverlayToggleDescription)
                }
                .toggleStyle(.switch)

                Picker(selection: $settings.liveSubtitleSourceModeRawValue) {
                    ForEach(LiveSubtitleSourceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                } label: {
                    Text(L10n.source)
                    Text(L10n.liveSubtitleSourceDescription)
                }
                .disabled(!settings.liveSubtitleOverlayEnabled)

                Picker(selection: $settings.liveSubtitleOverlaySegmentCount) {
                    ForEach(1 ..< 6, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                } label: {
                    Text(L10n.liveSubtitleOverlaySegmentCount)
                    Text(L10n.liveSubtitleOverlaySegmentCountDescription)
                }
                .disabled(!settings.liveSubtitleOverlayEnabled)
            } header: {
                Text(L10n.liveSubtitleOverlay)
            } footer: {
                VStack(alignment: .leading) {
                    Text(L10n.liveSubtitleOverlayDescription)
                    if !settings.liveSubtitleOverlayEnabled {
                        Text(L10n.enableLiveSubtitlesToConfigure)
                    }
                }
            }

            Section {
                TextField(L10n.searchLanguages, text: $localeSearchText)
                    .textFieldStyle(.roundedBorder)

                if isLoadingLocales {
                    ProgressView(L10n.loadingLanguages)
                } else {
                    localeSelectionList
                    localeSelectionFooter
                }
            } header: {
                Text(L10n.displayLanguages)
            } footer: {
                Text(L10n.displayLanguagesDescription)
            }
        }
        .formStyle(.grouped)
        .task {
            await loadSupportedLocales()
        }
    }

    // MARK: - Private

    @ViewBuilder
    private var localeSelectionList: some View {
        let searchedLocales = searchFilteredLocales
        if searchedLocales.isEmpty {
            Text(L10n.noMatchingLanguages)
                .foregroundStyle(.secondary)
        } else {
            ForEach(searchedLocales, id: \.identifier) { locale in
                localeRow(for: locale)
            }
        }
    }

    private var localeSelectionFooter: some View {
        HStack(alignment: .center, spacing: 12) {
            let enabled = settings.enabledLocaleIdentifiers
            Text(localeSelectionSummary(for: enabled))
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()

            if !enabled.isEmpty {
                Button(L10n.uncheckAll) {
                    settings.enabledLocaleIdentifiers = []
                }
            }

            if enabled.count != supportedLocales.count {
                Button(L10n.showAll) {
                    settings.enabledLocaleIdentifiers = Set(supportedLocales.map(\.identifier))
                }
            }
        }
    }

    private func localeSelectionSummary(for enabled: Set<String>) -> String {
        if enabled.isEmpty {
            return L10n.allLanguagesShown
        }
        return L10n.languagesSelected(enabled.count)
    }

    private var targetLanguageOptions: [TranscriptTranslationLanguageOption] {
        let displayLocale = settings.appLanguage.locale
        let options = TranscriptTranslationLanguage.availableTargetLanguages(
            from: supportedLocales,
            locale: displayLocale
        )
        if options.contains(where: { $0.identifier == settings.transcriptTranslationTargetLanguage }) {
            return options
        }

        return options + [
            TranscriptTranslationLanguageOption(
                identifier: settings.transcriptTranslationTargetLanguage,
                displayName: TranscriptTranslationLanguage.displayName(
                    for: settings.transcriptTranslationTargetLanguage,
                    locale: displayLocale
                )
            ),
        ]
    }

    private var searchFilteredLocales: [Locale] {
        guard !localeSearchText.isEmpty else { return supportedLocales }
        let query = localeSearchText.lowercased()
        return supportedLocales.filter { locale in
            let name = locale.localizedString(forIdentifier: locale.identifier) ?? ""
            return name.lowercased().contains(query)
                || locale.identifier.lowercased().contains(query)
        }
    }

    private func toggleLocale(_ identifier: String) {
        var enabled = settings.enabledLocaleIdentifiers
        if enabled.isEmpty {
            enabled = Set(supportedLocales.map(\.identifier))
            enabled.remove(identifier)
        } else if enabled.contains(identifier) {
            enabled.remove(identifier)
        } else {
            enabled.insert(identifier)
        }
        settings.enabledLocaleIdentifiers = enabled
    }

    private func localeSelectionBinding(for identifier: String) -> Binding<Bool> {
        Binding {
            settings.isLocaleEnabled(identifier)
        } set: { _ in
            toggleLocale(identifier)
        }
    }

    private func localeRow(for locale: Locale) -> some View {
        let identifier = locale.identifier
        return Toggle(isOn: localeSelectionBinding(for: identifier)) {
            VStack(alignment: .leading, spacing: 4) {
                Text(locale.localizedString(forIdentifier: identifier) ?? identifier)

                Text(identifier)
            }
        }
        .toggleStyle(.checkbox)
    }

    private func loadSupportedLocales() async {
        isLoadingLocales = true
        let locales = await SpeechTranscriber.supportedLocales
        supportedLocales = locales.sortedByLocalizedName()
        isLoadingLocales = false
    }
}
