import Speech
import SwiftUI

/// 設定画面「文字起こし」タブ。認識方法と利用する言語を管理する。
struct TranscriptionSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var supportedLocales: [Locale] = []
    @State private var isLoadingLocales = true
    @State private var localeSearchText = ""

    var body: some View {
        Form {
            Section {
                Picker(L10n.transcriptionMethod, selection: $settings.transcriptionMode) {
                    ForEach(TranscriptionMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(transcriptionModeDescription)
            }

            if settings.transcriptionMode == .batch {
                Section {
                    Picker(selection: $settings.batchTranscriptionStallTimeout) {
                        ForEach(BatchTranscriptionStallTimeout.allCases) { timeout in
                            Text(timeout.displayName).tag(timeout)
                        }
                    } label: {
                        Text(L10n.batchTranscriptionStallTimeout)
                        Text(L10n.batchTranscriptionStallTimeoutDescription)
                    }
                    .pickerStyle(.menu)

                    Toggle(isOn: $settings.retainAudioAfterBatchTranscription) {
                        Text(L10n.retainBatchAudio)
                        Text(L10n.retainBatchAudioDescription)
                    }
                    .toggleStyle(.switch)

                    Toggle(isOn: $settings.generateSummaryAfterBatchTranscription) {
                        Text(L10n.generateSummaryAfterBatchTranscription)
                        Text(L10n.generateSummaryAfterBatchTranscriptionDescription)
                    }
                    .toggleStyle(.switch)

                    Toggle(isOn: $settings.exportBatchSummaryToVault) {
                        Text(L10n.exportBatchSummaryToVault)
                        Text(L10n.exportBatchSummaryToVaultDescription)
                    }
                    .toggleStyle(.switch)
                    .disabled(!settings.generateSummaryAfterBatchTranscription)

                    Toggle(isOn: $settings.exportBatchSummaryToGoogleDocs) {
                        Text(L10n.exportBatchSummaryToGoogleDocs)
                        Text(L10n.exportBatchSummaryToGoogleDocsDescription)
                    }
                    .toggleStyle(.switch)
                    .disabled(!settings.generateSummaryAfterBatchTranscription)
                } header: {
                    Text(L10n.batchTranscription)
                }
            }

            Section {
                Toggle(isOn: $settings.forceEchoCancellationForExternalMicrophone) {
                    Text(L10n.externalMicrophoneEchoCancellation)
                    Text(L10n.externalMicrophoneEchoCancellationDescription)
                }
                .toggleStyle(.switch)
            } header: {
                Text(L10n.audioInput)
            } footer: {
                Text(L10n.builtInMicrophoneEchoCancellationDescription)
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

    private var transcriptionModeDescription: String {
        switch settings.transcriptionMode {
        case .realtime: L10n.realtimeTranscriptionDescription
        case .batch: L10n.batchTranscriptionDescription
        }
    }

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
        return supportedLocales.filter { locale in
            let name = locale.localizedString(forIdentifier: locale.identifier) ?? ""
            return name.localizedStandardContains(localeSearchText)
                || locale.identifier.localizedStandardContains(localeSearchText)
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
