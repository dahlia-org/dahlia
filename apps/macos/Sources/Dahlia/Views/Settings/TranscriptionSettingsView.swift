import SwiftUI

/// 選択中のアカウントの文字起こし設定。
struct TranscriptionSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @Bindable private var workspaceSettings = WorkspaceAISettingsModel.shared
    let supportedLocales: [Locale]
    let isLoadingLocales: Bool

    var body: some View {
        Section {
            TranscriptionLanguagePicker(supportedLocales: supportedLocales)
                .disabled(isLoadingLocales)
            LabeledContent(L10n.transcriptionModel, value: "Apple Speech")
        } header: {
            Text(L10n.transcription)
                .font(.dahliaSectionHeader)
        }

        if let error = workspaceSettings.errorMessage {
            Section { SettingsStatusMessage(text: error, systemImage: "exclamationmark.triangle", tint: .orange) }
        }

        Section {
            if settings.currentWorkspace != nil {
                Toggle(L10n.automaticRecordingProcessing, isOn: $workspaceSettings.generationSettings.automaticProcessing)
                    .toggleStyle(.dahliaSwitch)
            }
            Toggle(isOn: $settings.exportBatchSummaryToWorkspace) {
                Text(L10n.exportBatchSummaryToWorkspace)
                Text(L10n.exportBatchSummaryToWorkspaceDescription)
            }
            .toggleStyle(.dahliaSwitch)
        } header: {
            Text(L10n.settingsAfterRecording)
                .font(.dahliaSectionHeader)
        }

        Section {
            Toggle(isOn: $settings.automaticMeetingEndRecordingStopEnabled) {
                Text(L10n.automaticMeetingEndRecordingStop)
                Text(L10n.automaticMeetingEndRecordingStopDescription)
            }
            .toggleStyle(.dahliaSwitch)
        } header: {
            Text(L10n.recordingStopDetection)
                .font(.dahliaSectionHeader)
        }
    }
}
