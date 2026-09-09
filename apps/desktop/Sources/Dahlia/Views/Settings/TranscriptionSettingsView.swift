import Speech
import SwiftUI

/// 設定画面「文字起こし」タブ。認識方法と利用する言語を管理する。
struct TranscriptionSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @Bindable private var accountSettings = ServerAccountSettingsModel.shared
    private var connectionID: UUID? { settings.currentVault?.accountConnectionId }
    private var processingMethods: [RecordingProcessingMethod] {
        connectionID.map { accountSettings.state(for: $0).recordingProcessingMethods } ?? [.transcript]
    }

    @State private var supportedLocales: [Locale] = []
    @State private var isLoadingLocales = true
    @State private var pendingShorterAudioRetentionPeriod: BatchAudioRetentionPeriod?
    @State private var isShowingAudioRetentionConfirmation = false

    var body: some View {
        Form {
            Section {
                Picker(L10n.processingMethod, selection: Binding(
                    get: { connectionID.flatMap { accountSettings.state(for: $0).settings?.summary?.method }
                        .flatMap(RecordingProcessingMethod.init(rawValue:)) ?? .transcript
                    },
                    set: { value in
                        if let connectionID { accountSettings.save(.init(summary: .init(method: value.rawValue)), connectionID: connectionID) }
                    }
                )) {
                    ForEach(processingMethods) { Text($0.displayName).tag($0) }
                }
                .disabled(processingMethods.isEmpty || (connectionID.map { !accountSettings.state(for: $0).canEdit } ?? true))
                Toggle(L10n.liveTranscriptDraft, isOn: $settings.liveTranscriptDraftEnabled)
                    .toggleStyle(.switch)
                Toggle(L10n.automaticRecordingProcessing, isOn: $settings.automaticRecordingProcessingEnabled)
                    .toggleStyle(.switch)
            }

            Group {
                Section {
                    DahliaMenuPicker(
                        title: L10n.transcriptionLanguage,
                        selection: $settings.transcriptionLocale,
                        options: transcriptionLocaleOptions.map(\.identifier)
                    ) { identifier in
                        Locale(identifier: identifier).localizedString(forIdentifier: identifier) ?? identifier
                    }
                    .disabled(isLoadingLocales)
                } footer: {
                    Text(L10n.transcriptionLanguageDescription)
                }

                Section {
                    DahliaMenuPicker(
                        title: L10n.batchTranscriptionStallTimeout,
                        description: L10n.batchTranscriptionStallTimeoutDescription,
                        selection: $settings.batchTranscriptionStallTimeout,
                        options: BatchTranscriptionStallTimeout.allCases,
                        label: \.displayName
                    )

                    DahliaMenuPicker(
                        title: L10n.batchAudioRetentionPeriod,
                        description: L10n.batchAudioRetentionPeriodDescription,
                        selection: audioRetentionPeriodSelection,
                        options: BatchAudioRetentionPeriod.allCases,
                        label: \.displayName
                    )

                    Toggle(isOn: $settings.exportBatchSummaryToVault) {
                        Text(L10n.exportBatchSummaryToVault)
                        Text(L10n.exportBatchSummaryToVaultDescription)
                    }
                    .toggleStyle(.switch)

                    Toggle(isOn: $settings.exportBatchSummaryToGoogleDocs) {
                        Text(L10n.exportBatchSummaryToGoogleDocs)
                        Text(L10n.exportBatchSummaryToGoogleDocsDescription)
                    }
                    .toggleStyle(.switch)
                } header: {
                    Text(L10n.processingConfirmationTitle)
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

        }
        .formStyle(.grouped)
        .confirmationDialog(
            L10n.shortenBatchAudioRetentionPeriodTitle,
            isPresented: $isShowingAudioRetentionConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.apply, role: .destructive, action: confirmShorterAudioRetentionPeriod)
            Button(L10n.cancel, role: .cancel, action: cancelShorterAudioRetentionPeriod)
        } message: {
            Text(L10n.shortenBatchAudioRetentionPeriodMessage)
        }
        .task {
            await loadSupportedLocales()
        }
    }

    // MARK: - Private

    private var audioRetentionPeriodSelection: Binding<BatchAudioRetentionPeriod> {
        Binding(
            get: { settings.batchAudioRetentionPeriod },
            set: { applyAudioRetentionPeriodChange($0) }
        )
    }

    private func applyAudioRetentionPeriodChange(_ newValue: BatchAudioRetentionPeriod) {
        guard newValue != settings.batchAudioRetentionPeriod else { return }
        guard newValue.isShorter(than: settings.batchAudioRetentionPeriod) else {
            settings.batchAudioRetentionPeriod = newValue
            return
        }
        pendingShorterAudioRetentionPeriod = newValue
        Task { @MainActor in
            await Task.yield()
            guard pendingShorterAudioRetentionPeriod == newValue else { return }
            isShowingAudioRetentionConfirmation = true
        }
    }

    private func confirmShorterAudioRetentionPeriod() {
        guard let pendingShorterAudioRetentionPeriod else { return }
        settings.batchAudioRetentionPeriod = pendingShorterAudioRetentionPeriod
        self.pendingShorterAudioRetentionPeriod = nil
    }

    private func cancelShorterAudioRetentionPeriod() {
        pendingShorterAudioRetentionPeriod = nil
    }

    private var transcriptionLocaleOptions: [Locale] {
        var locales = supportedLocales.filter { settings.isLanguageEnabled($0.identifier) }
        if !locales.contains(where: { $0.identifier == settings.transcriptionLocale }) {
            locales.append(Locale(identifier: settings.transcriptionLocale))
        }
        return locales.sortedByLocalizedName()
    }

    private func loadSupportedLocales() async {
        isLoadingLocales = true
        let locales = await SpeechSupportedLocales.load()
        supportedLocales = locales.sortedByLocalizedName()
        isLoadingLocales = false
    }
}
