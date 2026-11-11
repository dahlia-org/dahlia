import SwiftUI

struct AccountProcessingSettingsView: View {
    let target: LocalSummarySettingsRows.Target
    @ObservedObject private var settings = AppSettings.shared
    @Bindable private var workspaceSettings = WorkspaceAISettingsModel.shared

    var body: some View {
        Group {
            if let error = workspaceSettings.errorMessage {
                Section { SettingsStatusMessage(text: error, systemImage: "exclamationmark.triangle", tint: .orange) }
            }
            if settings.currentWorkspace != nil {
                if target == .summary {
                    Section {
                        LabeledContent(L10n.summaryProcessingLocation, value: L10n.localProcessing)
                        LocalSummarySettingsRows()
                        Picker(L10n.summaryStyle, selection: $workspaceSettings.generationSettings.summary.style) {
                            ForEach(SummaryStyle.allCases) { Text($0.displayName).font(.dahliaBody).tag($0) }
                        }
                        Text(workspaceSettings.generationSettings.summary.style.description).foregroundStyle(.secondary)
                    } header: {
                        Text(L10n.settingsSummaryOutput)
                            .font(.dahliaSectionHeader)
                    }
                } else {
                    Section {
                        Toggle(L10n.imageAnalysisEnabled, isOn: $workspaceSettings.generationSettings.imageAnalysis.enabled)
                        LocalSummarySettingsRows(targets: [.imageAnalysis])
                    } header: {
                        Text(L10n.imageAnalysis)
                            .font(.dahliaSectionHeader)
                    }
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
        if let error = workspaceSettings.errorMessage {
            Section { SettingsStatusMessage(text: error, systemImage: "exclamationmark.triangle", tint: .orange) }
        }
        if let workspace = settings.currentWorkspace {
            Section {
                Picker(L10n.summaryOutputLanguage, selection: $workspaceSettings.generationSettings.outputLanguage) {
                    ForEach(SummaryLanguage.allCases) { Text($0.displayName).font(.dahliaBody).tag($0) }
                }
                Text(L10n.settingsOutputLanguageDescription).foregroundStyle(.secondary)
            } header: {
                Text(L10n.generatedContentLanguage)
                    .font(.dahliaSectionHeader)
            }
            .disabled(!workspace.allowsWorkspaceManagement)
        }
    }
}
