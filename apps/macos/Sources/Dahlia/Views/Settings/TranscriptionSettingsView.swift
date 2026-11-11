import Speech
import SwiftUI

/// 選択中のアカウントの文字起こし設定。
struct TranscriptionSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @Bindable private var workspaceSettings = WorkspaceAISettingsModel.shared
    @State private var supportedLocales: [Locale] = []
    @State private var isLoadingLocales = true

    var body: some View {
        Form {
            Section {
                DahliaMenuPicker(
                    title: L10n.transcriptionLanguage,
                    description: L10n.appleSpeechSettingsScopeDescription,
                    selection: transcriptionLanguageSelection,
                    options: [SettingsLanguageOptions.automaticTranscription] + SettingsLanguageOptions.locales(
                        from: supportedLocales.filter { settings.isLanguageEnabled($0.identifier) },
                        including: settings.transcriptionLocale
                    ).map(\.identifier)
                ) { identifier in
                    identifier == SettingsLanguageOptions.automaticTranscription
                        ? L10n.auto
                        : Locale(identifier: identifier).localizedString(forIdentifier: identifier) ?? identifier
                }
                .disabled(isLoadingLocales)
                LabeledContent(L10n.transcriptionModel, value: "Apple Speech")
            } header: {
                Text(L10n.transcription)
                    .font(.dahliaSectionHeader)
            }

            if let error = workspaceSettings.errorMessage {
                Section { SettingsStatusMessage(text: error, systemImage: "exclamationmark.triangle", tint: .orange) }
            }

            // Saved with the account's AI settings, which need an open workspace.
            if settings.currentWorkspace != nil {
                Section {
                    Toggle(L10n.liveTranscriptDraft, isOn: $workspaceSettings.generationSettings.liveTranscriptDraft)
                        .toggleStyle(.switch)
                } header: {
                    Text(L10n.settingsDuringRecording)
                        .font(.dahliaSectionHeader)
                }
            }

            Section {
                if settings.currentWorkspace != nil {
                    Toggle(L10n.automaticRecordingProcessing, isOn: $workspaceSettings.generationSettings.automaticProcessing)
                        .toggleStyle(.switch)
                }
                Toggle(isOn: $settings.exportBatchSummaryToWorkspace) {
                    Text(L10n.exportBatchSummaryToWorkspace)
                    Text(L10n.exportBatchSummaryToWorkspaceDescription)
                }
                .toggleStyle(.switch)
            } header: {
                Text(L10n.settingsAfterRecording)
                    .font(.dahliaSectionHeader)
            }

            Section {
                Toggle(isOn: $settings.automaticMeetingEndRecordingStopEnabled) {
                    Text(L10n.automaticMeetingEndRecordingStop)
                    Text(L10n.automaticMeetingEndRecordingStopDescription)
                }
                .toggleStyle(.switch)
            } header: {
                Text(L10n.recordingStopDetection)
                    .font(.dahliaSectionHeader)
            }

        }
        .formStyle(.grouped)
        .font(.dahliaBody)
        .task {
            supportedLocales = await SpeechSupportedLocales.load().sortedByLocalizedName()
            isLoadingLocales = false
        }
    }

    // MARK: - Private

    private var transcriptionLanguageSelection: Binding<String> {
        Binding(
            get: {
                SettingsLanguageOptions.transcriptionSelection(
                    localeIdentifier: settings.transcriptionLocale,
                    detectsAutomatically: settings.automaticTranscriptionLanguageDetectionEnabled
                )
            },
            set: { selection in
                let resolved = SettingsLanguageOptions.resolvedTranscriptionSelection(
                    selection,
                    currentLocaleIdentifier: settings.transcriptionLocale
                )
                settings.transcriptionLocale = resolved.localeIdentifier
                settings.automaticTranscriptionLanguageDetectionEnabled = resolved.detectsAutomatically
            }
        )
    }

}
