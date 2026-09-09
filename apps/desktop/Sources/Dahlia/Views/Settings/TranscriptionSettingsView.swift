import Speech
import SwiftUI

/// 文字起こしと要約の処理場所、およびこのMac固有の録音設定を管理する。
struct TranscriptionSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @Bindable private var accountSettings = ServerAccountSettingsModel.shared
    @State private var accountController = DahliaCloudAccountController.shared
    private var connectionID: UUID? { settings.currentVault?.accountConnectionId }
    private var serverState: ServerAccountSettingsModel.State? { connectionID.map(accountSettings.state(for:)) }
    private var mode: ServerAccountSettings.SummaryMode { serverState?.settings?.summary?.mode ?? .local }
    private var canSelectRemote: Bool { serverState?.summaryMethods.contains("audio") == true }
    private var accountName: String {
        guard let connectionID else { return L10n.localAccount }
        return accountController.connections.first { $0.id == connectionID }?.displayName ?? L10n.dahliaAccount
    }

    @State private var supportedLocales: [Locale] = []
    @State private var isLoadingLocales = true
    @State private var pendingShorterAudioRetentionPeriod: BatchAudioRetentionPeriod?
    @State private var isShowingAudioRetentionConfirmation = false

    var body: some View {
        Form {
            Section {
                LabeledContent(L10n.appliesToAccount, value: accountName)
                LabeledContent(L10n.settingsScope, value: connectionID == nil ? L10n.localAccount : L10n.syncedDahliaAccount)
                if let connectionID {
                    Picker(L10n.processingLocation, selection: Binding(
                        get: { mode },
                        set: { accountSettings.save(.init(summary: .init(mode: $0)), connectionID: connectionID) }
                    )) {
                        Text(L10n.localProcessing).tag(ServerAccountSettings.SummaryMode.local)
                        if canSelectRemote || mode == .remote {
                            Text(L10n.remoteProcessing).tag(ServerAccountSettings.SummaryMode.remote)
                                .disabled(!canSelectRemote)
                        }
                    }
                    .disabled(serverState?.canEdit != true)
                    if serverState?.isLoading == true {
                        LabeledContent(L10n.processingLocation) { ProgressView().controlSize(.small) }
                    } else if let error = serverState?.errorMessage {
                        SettingsStatusMessage(text: error, systemImage: "exclamationmark.triangle.fill", tint: .red)
                        Button(L10n.retry) { accountSettings.refresh(connectionID: connectionID) }
                    } else if mode == .remote, !canSelectRemote {
                        SettingsStatusMessage(text: L10n.serverSummaryUnavailable, systemImage: "exclamationmark.triangle.fill", tint: .orange)
                    }
                } else {
                    LabeledContent(L10n.processingLocation, value: L10n.localProcessing)
                }
            } header: {
                Text(L10n.transcriptionAndSummary)
            } footer: {
                Text(connectionID == nil ? L10n.localAccountScopeDescription : L10n.syncedAccountScopeDescription)
            }

            if mode == .local {
                LocalSummarySettingsSection()
            } else if let connectionID {
                ServerSummarySettingsSection(connectionID: connectionID)
            }

            Section {
                Toggle(L10n.liveTranscriptDraft, isOn: $settings.liveTranscriptDraftEnabled)
                    .toggleStyle(.switch)
                Toggle(L10n.automaticRecordingProcessing, isOn: $settings.automaticRecordingProcessingEnabled)
                    .toggleStyle(.switch)
            } header: {
                Text(L10n.thisMac)
            } footer: {
                Text(L10n.thisMacSettingsDescription)
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
        .task(id: connectionID) {
            if let connectionID, let task = accountSettings.refresh(connectionID: connectionID) { await task.value }
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
