import Speech
import SwiftUI

/// 設定画面「文字起こし」タブ。認識方法と利用する言語を管理する。
struct TranscriptionSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @AppStorage(AppSettings.generateSummaryAfterBatchTranscriptionUserDefaultsKey)
    private var generateSummaryAfterBatchTranscription = false
    @AppStorage(AppSettings.exportBatchSummaryToVaultUserDefaultsKey)
    private var exportBatchSummaryToVault = true
    @AppStorage(AppSettings.exportBatchSummaryToGoogleDocsUserDefaultsKey)
    private var exportBatchSummaryToGoogleDocs = false
    @State private var supportedLocales: [Locale] = []
    @State private var isLoadingLocales = true
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
                Picker(L10n.languageRange, selection: languageScopeBinding) {
                    ForEach(TranscriptionLanguageScope.allCases) { scope in
                        Text(scope.displayName).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(isLoadingLocales)

                if settings.transcriptionLanguageScope == .selected {
                    TextField(L10n.searchLanguages, text: $localeSearchText)
                        .textFieldStyle(.roundedBorder)

                    if isLoadingLocales {
                        ProgressView(L10n.loadingLanguages)
                    } else {
                        localeSelectionList
                    }
                }
            } header: {
                Text(L10n.transcriptionLanguages)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(languageScopeDescription)
                    if settings.transcriptionLanguageScope == .selected {
                        Text(L10n.languagesSelected(settings.enabledLocaleIdentifiers.count))
                    }
                }
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

    private var languageScopeDescription: String {
        switch settings.transcriptionLanguageScope {
        case .all: L10n.allTranscriptionLanguagesDescription
        case .selected: L10n.selectedTranscriptionLanguagesDescription
        }
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
        if enabled.contains(identifier) {
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

    private var languageScopeBinding: Binding<TranscriptionLanguageScope> {
        Binding {
            settings.transcriptionLanguageScope
        } set: { scope in
            settings.transcriptionLanguageScope = scope
            if scope == .selected, settings.enabledLocaleIdentifiers.isEmpty {
                seedDefaultEnabledLocales()
            }
        }
    }

    private func seedDefaultEnabledLocales() {
        let supportedIdentifiers = Set(supportedLocales.map(\.identifier))
        guard !supportedIdentifiers.isEmpty else { return }
        settings.enabledLocaleIdentifiers = AppSettings.defaultEnabledLocaleIdentifiers
            .intersection(supportedIdentifiers)
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
        if settings.transcriptionLanguageScope == .selected,
           settings.enabledLocaleIdentifiers.isEmpty {
            seedDefaultEnabledLocales()
        }
        isLoadingLocales = false
    }
}
