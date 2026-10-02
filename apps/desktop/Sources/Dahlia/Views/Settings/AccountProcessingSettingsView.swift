import SwiftUI

struct WorkspaceProcessingSettingsView: View {
    let onOpenMacTranscription: () -> Void
    let onOpenMacInference: () -> Void
    @ObservedObject private var settings = AppSettings.shared
    @Bindable private var workspaceSettings = WorkspaceAISettingsModel.shared

    var body: some View {
        Form {
            if let error = workspaceSettings.errorMessage {
                Section { SettingsStatusMessage(text: error, systemImage: "exclamationmark.triangle", tint: .orange) }
            }
            if let workspace = settings.currentWorkspace {
                Section(L10n.generatedContentLanguage) {
                    Picker(L10n.summaryOutputLanguage, selection: $workspaceSettings.generationSettings.outputLanguage) {
                        ForEach(SummaryLanguage.allCases) { Text($0.displayName).tag($0) }
                    }
                    Text(L10n.settingsOutputLanguageDescription).foregroundStyle(.secondary)
                }
                .disabled(!workspace.allowsWorkspaceManagement)
                Section(L10n.transcription) {
                    LabeledContent(L10n.transcriptionModel, value: "Apple Speech")
                    Button(L10n.macTranscriptionPreferences, systemImage: "arrow.right", action: onOpenMacTranscription)
                    Toggle(L10n.liveTranscriptDraft, isOn: $workspaceSettings.generationSettings.liveTranscriptDraft)
                }
                Section(L10n.settingsSummaryOutput) {
                    Text(L10n.accountInferenceSettingsDescription).foregroundStyle(.secondary)
                    LabeledContent(L10n.summaryProcessingLocation, value: L10n.localProcessing)
                    Picker(L10n.summaryStyle, selection: $workspaceSettings.generationSettings.summary.style) {
                        ForEach(SummaryStyle.allCases) { Text($0.displayName).tag($0) }
                    }
                    Text(workspaceSettings.generationSettings.summary.style.description).foregroundStyle(.secondary)
                    if workspaceSettings.isLocalAccount {
                        Button(L10n.macInferencePreferences, action: onOpenMacInference)
                    }
                    LocalSummarySettingsRows()
                }
                Section(L10n.settingsAfterRecording) {
                    Toggle(L10n.automaticRecordingProcessing, isOn: $workspaceSettings.generationSettings.automaticProcessing)
                }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
    }
}
