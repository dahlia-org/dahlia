import Speech
import SwiftUI

struct WorkspaceProcessingSettingsView: View {
    let onOpenMacInference: () -> Void

    @ObservedObject private var settings = AppSettings.shared
    @Bindable private var workspaceSettings = WorkspaceAISettingsModel.shared
    @Bindable private var accountSettings = ServerAccountSettingsModel.shared

    @State private var supportedLocales: [Locale] = []

    private var workspace: WorkspaceRecord? { settings.currentWorkspace }
    private var connectionID: UUID? { workspace?.accountConnectionId }
    private var canTranscribeRemotely: Bool { connectionID.map { accountSettings.state(for: $0).summaryMethods.contains("audio") } == true }
    private var canEdit: Bool { workspace?.allowsWorkspaceManagement == true }

    var body: some View {
        Form {
            Section {
                LabeledContent(L10n.workspace, value: workspace?.name ?? L10n.noWorkspaces)
                Text(L10n.workspaceGenerationSettingsDescription).foregroundStyle(.secondary)
                if let error = workspaceSettings.errorMessage {
                    SettingsStatusMessage(text: error, systemImage: "exclamationmark.triangle", tint: .orange)
                }
            }

            if workspace != nil {
                Section(L10n.initialTranscription) {
                    if connectionID != nil {
                        Picker(L10n.processingLocation, selection: $workspaceSettings.generationSettings.processing.location) {
                            Text(L10n.localProcessing).tag(WorkspaceGenerationSettings.SummaryMode.local)
                            Text(L10n.remoteProcessing).tag(WorkspaceGenerationSettings.SummaryMode.remote)
                                .disabled(!canTranscribeRemotely)
                        }
                    } else {
                        LabeledContent(L10n.processingLocation, value: L10n.localProcessing)
                    }
                    if connectionID != nil, !canTranscribeRemotely {
                        Text(L10n.serverSummaryUnavailable).foregroundStyle(.secondary)
                    }
                    if connectionID == nil || workspaceSettings.generationSettings.processing.location == .local {
                        LabeledContent(L10n.transcriptionModel, value: "Apple Speech")
                    }
                    Picker(L10n.transcriptionLanguage, selection: $workspaceSettings.generationSettings.transcription.localeIdentifier) {
                        ForEach(SettingsLanguageOptions.locales(
                            from: supportedLocales, including: workspaceSettings.generationSettings.transcription.localeIdentifier
                        ), id: \.identifier) { locale in
                            Text(locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier).tag(locale.identifier)
                        }
                    }
                    Toggle(
                        L10n.automaticDetectionMultilingualTitle,
                        isOn: $workspaceSettings.generationSettings.transcription.automaticLanguageDetection
                    )
                    Toggle(L10n.liveTranscriptDraft, isOn: $workspaceSettings.generationSettings.transcription.liveTranscriptDraft)
                }
                .disabled(!canEdit)
                WorkspaceTranscriptionLanguagesSection().disabled(!canEdit)

                Section(L10n.retranscription) {
                    LabeledContent(
                        L10n.processingMethod,
                        value: connectionID == nil ? L10n.retranscriptionAppleSpeech : L10n.retranscriptionGemini
                    )
                    Text(connectionID == nil
                        ? L10n.localRetranscriptionPolicyDescription
                        : L10n.serverRetranscriptionPolicyDescription)
                        .foregroundStyle(.secondary)
                    Text(L10n.retranscriptionKeepsSummary).foregroundStyle(.secondary)
                }

                Section {
                    Picker(L10n.summaryStyle, selection: $workspaceSettings.generationSettings.summary.style) {
                        ForEach(SummaryStyle.allCases) { Text($0.displayName).tag($0) }
                    }
                    Text(workspaceSettings.generationSettings.summary.style.description).foregroundStyle(.secondary)
                    Picker(L10n.summaryOutputLanguage, selection: $workspaceSettings.generationSettings.outputLanguage) {
                        ForEach(SummaryLanguage.allCases) { Text($0.displayName).tag($0) }
                    }
                } header: {
                    Text(L10n.settingsSummaryOutput)
                } footer: {
                    Text(L10n.settingsOutputLanguageDescription)
                }
                .disabled(!canEdit)

                Section {
                    LabeledContent(L10n.processingLocation, value: connectionID == nil ? L10n.localProcessing : L10n.remoteProcessing)
                    if connectionID == nil {
                        Button(L10n.macInferencePreferences, systemImage: "arrow.right", action: onOpenMacInference)
                    }
                } header: {
                    Text(L10n.summaryModel)
                } footer: {
                    Text(connectionID == nil ? L10n.usesMacInferencePreferences : L10n.settingsServerProcessingDescription)
                }
                if let connectionID {
                    ServerSummarySettingsSection(connectionID: connectionID).disabled(!canEdit)
                } else {
                    LocalSummarySettingsSection(canEdit: canEdit)
                }
                Section(L10n.settingsAfterRecording) {
                    Toggle(L10n.automaticRecordingProcessing, isOn: $workspaceSettings.generationSettings.automaticProcessing)
                }
                .disabled(!canEdit)
            }
        }
        .formStyle(.grouped)
        .task { supportedLocales = await SpeechSupportedLocales.load() }
        .task(id: connectionID) {
            if let connectionID, let task = accountSettings.refresh(connectionID: connectionID) { await task.value }
        }
    }
}
