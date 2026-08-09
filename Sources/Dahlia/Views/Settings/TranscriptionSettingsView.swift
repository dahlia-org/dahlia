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
    @StateObject private var speakerModel = SpeakerModelSettingsViewModel()

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.isRealtimeTranscriptionEnabled) {
                    Text(L10n.enableRealtimeTranscription)
                    Text(L10n.realtimeTranscriptionDescription)
                }
                .toggleStyle(.switch)

                if !settings.isRealtimeTranscriptionEnabled {
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

            // Speaker identification is batch-only, but keeping the control visible explains
            // why it is unavailable instead of making the feature impossible to discover.
            Section {
                Toggle(isOn: speakerIdentificationBinding) {
                    Text(L10n.speakerIdentification)
                    Text(L10n.speakerIdentificationDescription)
                }
                .toggleStyle(.switch)
                .disabled(settings.isRealtimeTranscriptionEnabled || speakerModel.isAcquiring)

                if settings.isRealtimeTranscriptionEnabled {
                    Text(L10n.speakerIdentificationBatchOnly)
                        .foregroundStyle(.secondary)
                }

                speakerModelStatus
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
            async let locales: Void = loadSupportedLocales()
            async let assets: Void = speakerModel.inspect(settings: settings)
            _ = await (locales, assets)
        }
    }

    // MARK: - Private

    private var speakerIdentificationBinding: Binding<Bool> {
        Binding {
            settings.speakerIdentificationEnabled || speakerModel.isAcquiring
        } set: { enabled in
            speakerModel.setEnabled(enabled, settings: settings)
        }
    }

    @ViewBuilder
    private var speakerModelStatus: some View {
        switch speakerModel.state {
        case .checking:
            ProgressView(L10n.checkingSpeakerModel)
        case let .acquiring(progress):
            ProgressView(
                value: Double(progress.completedByteCount),
                total: Double(max(1, progress.totalByteCount))
            ) {
                Text(L10n.downloadingSpeakerModel)
            } currentValueLabel: {
                Text(L10n.speakerModelDownloadProgress(
                    completed: progress.completedByteCount,
                    total: progress.totalByteCount
                ))
            }
            Button(L10n.cancel) {
                speakerModel.setEnabled(false, settings: settings)
            }
        case let .available(managedByteCount):
            LabeledContent(L10n.speakerModelManagedStorage) {
                Text(managedByteCount, format: .byteCount(style: .file))
            }
        case let .unavailable(managedByteCount):
            speakerModelStorageIfNeeded(managedByteCount)
            Button(L10n.downloadSpeakerModel) {
                speakerModel.acquire(settings: settings)
            }
            .disabled(settings.isRealtimeTranscriptionEnabled)
        case let .failed(managedByteCount):
            Text(L10n.speakerModelDownloadFailed)
                .foregroundStyle(.red)
            speakerModelStorageIfNeeded(managedByteCount)
            Button(L10n.retrySpeakerModelDownload) {
                speakerModel.acquire(settings: settings)
            }
            .disabled(settings.isRealtimeTranscriptionEnabled)
        }
    }

    @ViewBuilder
    private func speakerModelStorageIfNeeded(_ byteCount: Int64) -> some View {
        if byteCount > 0 {
            LabeledContent(L10n.speakerModelManagedStorage) {
                Text(byteCount, format: .byteCount(style: .file))
            }
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
