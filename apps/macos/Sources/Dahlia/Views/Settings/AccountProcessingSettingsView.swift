import SwiftUI

struct AccountProcessingSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @Bindable private var workspaceSettings = WorkspaceAISettingsModel.shared

    var body: some View {
        Group {
            if let error = workspaceSettings.errorMessage {
                Section { SettingsStatusMessage(text: error, systemImage: "exclamationmark.triangle", tint: .orange) }
            }
            if settings.currentWorkspace != nil {
                Section {
                    LabeledContent(L10n.transcriptionModel, value: "Apple Speech")
                    Toggle(L10n.liveTranscriptDraft, isOn: $workspaceSettings.generationSettings.liveTranscriptDraft)
                } header: {
                    Text(L10n.transcription)
                } footer: {
                    Text(L10n.settingsAccountIntro)
                }
                Section(L10n.settingsSummaryOutput) {
                    LabeledContent(L10n.summaryProcessingLocation, value: L10n.localProcessing)
                    LocalSummarySettingsRows()
                    Picker(L10n.summaryStyle, selection: $workspaceSettings.generationSettings.summary.style) {
                        ForEach(SummaryStyle.allCases) { Text($0.displayName).tag($0) }
                    }
                    Text(workspaceSettings.generationSettings.summary.style.description).foregroundStyle(.secondary)
                }
                Section(L10n.imageAnalysis) {
                    Toggle(L10n.imageAnalysisEnabled, isOn: $workspaceSettings.generationSettings.imageAnalysis.enabled)
                    LocalSummarySettingsRows(imageAnalysis: true)
                        .disabled(!workspaceSettings.generationSettings.imageAnalysis.enabled)
                }
                Section(L10n.settingsAfterRecording) {
                    Toggle(L10n.automaticRecordingProcessing, isOn: $workspaceSettings.generationSettings.automaticProcessing)
                }
            } else {
                ContentUnavailableView(L10n.noWorkspaceSelected, systemImage: "person.crop.circle")
            }
        }
        .toggleStyle(.switch)
    }
}

struct WorkspaceProcessingSettingsView: View {
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
            } else {
                ContentUnavailableView(L10n.noWorkspaceSelected, systemImage: ProjectIcon.workspace.systemImageName)
            }
        }
        .formStyle(.grouped)
    }
}
