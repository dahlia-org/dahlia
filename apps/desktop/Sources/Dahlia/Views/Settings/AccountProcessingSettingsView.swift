import SwiftUI

struct WorkspaceProcessingSettingsView: View {
    let onOpenMacTranscription: () -> Void
    let onOpenMacInference: () -> Void

    @ObservedObject private var settings = AppSettings.shared
    @Bindable private var workspaceSettings = WorkspaceAISettingsModel.shared
    @Bindable private var accountSettings = ServerAccountSettingsModel.shared

    private var workspace: WorkspaceRecord? { settings.currentWorkspace }
    private var connectionID: UUID? { workspace?.accountConnectionId }
    private var canTranscribeRemotely: Bool { connectionID.map { accountSettings.state(for: $0).summaryMethods.contains("audio") } == true }
    private var canEdit: Bool { workspace?.allowsWorkspaceManagement == true }

    var body: some View {
        Form {
            if let error = workspaceSettings.errorMessage, error != L10n.databricksProfileRequired {
                Section {
                    SettingsStatusMessage(text: error, systemImage: "exclamationmark.triangle", tint: .orange)
                }
            }

            if workspace != nil {
                Section(L10n.generatedContentLanguage) {
                    Picker(L10n.summaryOutputLanguage, selection: $workspaceSettings.generationSettings.outputLanguage) {
                        ForEach(SummaryLanguage.allCases) { Text($0.displayName).tag($0) }
                    }
                    Text(L10n.settingsOutputLanguageDescription).foregroundStyle(.secondary)
                }
                .disabled(!canEdit)

                Section(L10n.transcription) {
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
                        Button(L10n.macTranscriptionPreferences, systemImage: "arrow.right", action: onOpenMacTranscription)
                    } else {
                        LabeledContent(L10n.transcriptionModel, value: "Gemini")
                    }
                    if workspaceSettings.generationSettings.processing.location == .remote {
                        Text(L10n.serverTranscriptionLanguageDescription).foregroundStyle(.secondary)
                    }
                }
                .disabled(!canEdit)

                Section {
                    Toggle(L10n.liveTranscriptDraft, isOn: $workspaceSettings.generationSettings.liveTranscriptDraft)
                        .toggleStyle(.switch)
                }
                .disabled(!canEdit)

                Section {
                    LabeledContent(L10n.summaryProcessingLocation, value: connectionID == nil ? L10n.localProcessing : L10n.remoteProcessing)
                    if connectionID != nil {
                        Text(L10n.serverSummaryProcessingDescription).foregroundStyle(.secondary)
                    }
                    Picker(L10n.summaryStyle, selection: $workspaceSettings.generationSettings.summary.style) {
                        ForEach(SummaryStyle.allCases) { Text($0.displayName).tag($0) }
                    }
                    Text(workspaceSettings.generationSettings.summary.style.description).foregroundStyle(.secondary)
                    if connectionID == nil {
                        LabeledContent(L10n.macInferencePreferences) {
                            Button(L10n.settings, action: onOpenMacInference)
                                .buttonStyle(.link)
                        }
                        LocalSummarySettingsRows(canEdit: canEdit)
                    } else if let connectionID {
                        ServerSummarySettingsSection(connectionID: connectionID)
                    }
                } header: {
                    Text(L10n.settingsSummaryOutput)
                }
                .disabled(!canEdit)

                Section(L10n.settingsAfterRecording) {
                    Toggle(L10n.automaticRecordingProcessing, isOn: $workspaceSettings.generationSettings.automaticProcessing)
                }
                .disabled(!canEdit)
            }
        }
        .formStyle(.grouped)
        .task(id: connectionID) {
            if let connectionID, let task = accountSettings.refresh(connectionID: connectionID) { await task.value }
        }
    }
}
