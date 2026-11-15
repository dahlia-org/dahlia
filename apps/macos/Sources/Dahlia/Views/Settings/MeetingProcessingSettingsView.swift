import Speech
import SwiftUI

struct MeetingProcessingSettingsView: View {
    @Environment(MainWindowNavigation.self) private var navigation
    @ObservedObject private var settings = AppSettings.shared
    @State private var supportedLocales: [Locale] = []
    @State private var isLoadingLocales = true

    var body: some View {
        @Bindable var navigation = navigation
        Form {
            Section {
                MeetingProcessingFlow(selection: $navigation.meetingProcessingSelection)
            } header: {
                Text(L10n.meetingProcessingFlowTitle)
                    .font(.dahliaSectionHeader)
            } footer: {
                Text(L10n.meetingProcessingFlowHint)
            }

            switch navigation.meetingProcessingSelection {
            case .transcription:
                TranscriptionSettingsView(supportedLocales: supportedLocales, isLoadingLocales: isLoadingLocales)
            case .liveTranscription:
                LiveSubtitleSettingsView(supportedLocales: supportedLocales, isLoadingLocales: isLoadingLocales)
            case .screenshots:
                ScreenshotSettingsView()
            case .workspace:
                Section {
                    Text(L10n.settingsOutputLanguageDescription)
                        .foregroundStyle(.secondary)
                    if let workspace = settings.currentWorkspace {
                        LabeledContent(L10n.workspace, value: workspace.name)
                        LabeledContent(L10n.generatedContentLanguage, value: workspace.generationSettings.outputLanguage.displayName)
                    }
                    Button(L10n.meetingProcessingOpenWorkspaceSettings) {
                        navigation.openSettings(category: .workspace)
                    }
                    .buttonStyle(.dahlia())
                } header: {
                    Text(L10n.workspaceSettings)
                        .font(.dahliaSectionHeader)
                }
            case .audio, .video, .summary, .imageAnalysis:
                EmptyView()
            }
        }
        .formStyle(.grouped)
        .font(.dahliaBody)
        .task {
            supportedLocales = await SpeechSupportedLocales.load().sortedByLocalizedName()
            isLoadingLocales = false
        }
    }
}
