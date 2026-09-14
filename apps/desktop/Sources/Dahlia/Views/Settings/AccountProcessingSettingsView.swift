import SwiftUI

struct WorkspaceProcessingSettingsView: View {
    let onOpenMacInference: () -> Void
    let onOpenLanguageSettings: () -> Void

    @ObservedObject private var settings = AppSettings.shared
    @Bindable private var workspaceSettings = WorkspaceAISettingsModel.shared
    @Bindable private var accountSettings = ServerAccountSettingsModel.shared

    private var workspace: WorkspaceRecord? { settings.currentWorkspace }
    private var connectionID: UUID? { workspace?.accountConnectionId }
    private var canEdit: Bool { workspace?.allowsWorkspaceManagement == true }
    private var location: WorkspaceGenerationSettings.SummaryMode { workspaceSettings.generationSettings.processing.location }
    private var canSelectRemote: Bool { connectionID.map { accountSettings.state(for: $0).summaryMethods.contains("audio") } == true }

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
                    if connectionID != nil {
                        Picker(L10n.processingLocation, selection: $workspaceSettings.generationSettings.processing.location) {
                            Text(L10n.localProcessing).tag(WorkspaceGenerationSettings.SummaryMode.local)
                            if canSelectRemote || location == .remote {
                                Text(L10n.remoteProcessing).tag(WorkspaceGenerationSettings.SummaryMode.remote)
                                    .disabled(!canSelectRemote)
                            }
                        }
                        .disabled(!canEdit)
                    } else {
                        LabeledContent(L10n.processingLocation, value: L10n.localProcessing)
                    }
                    if location == .local {
                        Button(L10n.macInferencePreferences, systemImage: "arrow.right", action: onOpenMacInference)
                    }
                    if connectionID != nil, !canSelectRemote {
                        Text(L10n.serverSummaryUnavailable).foregroundStyle(.secondary)
                    }
                } header: {
                    Text(L10n.transcriptionAndSummary)
                } footer: {
                    Text(location == .local ? L10n.usesMacInferencePreferences : L10n.settingsServerProcessingDescription)
                }

                if location == .local {
                    LocalSummarySettingsSection(canEdit: canEdit)
                } else if let connectionID {
                    ServerSummarySettingsSection(connectionID: connectionID).disabled(!canEdit)
                }
                if let connectionID {
                    ServerAccountLanguageSettingsSection(connectionID: connectionID)
                        .id("server-languages-\(connectionID)")
                } else {
                    Section {
                        LabeledContent(L10n.imageAnalysisLanguages) {
                            Button(L10n.openLanguageSettings, action: onOpenLanguageSettings)
                        }
                    } footer: {
                        Text(L10n.settingsLocalAnalysisLanguages)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: connectionID) {
            if let connectionID, let task = accountSettings.refresh(connectionID: connectionID) { await task.value }
        }
    }
}
