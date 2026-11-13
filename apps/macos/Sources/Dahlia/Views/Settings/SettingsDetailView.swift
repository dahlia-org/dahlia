import SwiftUI

struct SettingsDetailView: View {
    @Environment(MainWindowNavigation.self) private var mainWindowNavigation
    @Binding var selection: SettingsCategory
    var captionViewModel: CaptionViewModel
    var sidebarViewModel: SidebarViewModel
    let appDatabase: AppDatabaseManager?
    var workspaceManagementModel: WorkspaceManagementModel
    let onShowUnprocessedRecordings: (UUID) -> Void

    @ObservedObject private var appSettings = AppSettings.shared
    @State private var dahliaAccountController = DahliaCloudAccountController.shared

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    EmptyView()
                } header: {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(SettingsNavigation.visibleSelection(selection).label)
                                .font(.dahliaHeadline)
                                .foregroundStyle(.primary)
                                .accessibilityAddTraits(.isHeader)
                            Text(scopeDescription)
                                .font(.dahliaBody)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if selection == .general {
                            Button(L10n.initialSetup, action: mainWindowNavigation.openSetupTour)
                                .buttonStyle(.dahlia())
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .font(.dahliaBody)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: 90)
            .padding(.top, DahliaDesign.windowHeaderHeight)

            selectedSettings
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .scrollContentBackground(.hidden)
        .scrollEdgeEffectHidden()
        .onChange(of: selection) { _, selection in
            if selection != .agents { mainWindowNavigation.dismissDahliaSignIn() }
        }
    }

    @ViewBuilder
    private var selectedSettings: some View {
        switch selection {
        case .general, .language:
            GeneralSettingsView()
        case .appearance, .eventDisplay:
            AppearanceSettingsView()
        case .accountsAndWorkspaces, .dahliaAccounts, .accountPreferences, .macInference, .modelProvider, .aiSummary, .mcp, .agents:
            AgentSettingsView()
                .onChange(of: dahliaAccountController.connections) {
                    Task { await workspaceManagementModel.loadWorkspaces() }
                }
        case .workspace, .workspacePreferences:
            Form {
                WorkspaceSettingsView(
                    appDatabase: appDatabase,
                    model: workspaceManagementModel,
                    currentWorkspace: appSettings.currentWorkspace,
                    accountConnections: dahliaAccountController.connections,
                    canSwitchWorkspace: canSwitchWorkspace,
                    onUpdateWorkspace: updateCurrentWorkspaceIfNeeded
                )
            }
            .formStyle(.grouped)
            .font(.dahliaBody)
            .onChange(of: workspaceManagementModel.workspaces.map { "\($0.id):\($0.accountConnectionId?.uuidString ?? "local")" }) {
                Task { await dahliaAccountController.reload() }
            }
        case .permissions:
            PermissionSettingsView()
        case .backups:
            DataProtectionSettingsView(
                dbQueue: sidebarViewModel.dbQueue,
                captionViewModel: captionViewModel,
                onShowUnprocessedRecordings: onShowUnprocessedRecordings
            )
        case .search:
            SearchSettingsView(database: appDatabase)
        case .meetings, .transcription, .recordingStopDetection, .liveSubtitles, .screenshots, .meetingLinks:
            MeetingSettingsView()
        case .dahliaMCP:
            MCPSettingsView(workspaces: workspaceManagementModel.workspaces, currentWorkspace: appSettings.currentWorkspace)
        case .calendar:
            CalendarSettingsView()
        case .instructions:
            InstructionsSettingsView(sidebarViewModel: sidebarViewModel)
        case .betaFeatures:
            BetaFeaturesSettingsView()
        case .audioDiagnostics:
            DebugSettingsView()
        }
    }

    private var scopeDescription: String {
        switch SettingsNavigation.visibleSelection(selection) {
        case .accountsAndWorkspaces: L10n.settingsAccountsIntro
        case .agents: L10n.settingsAgentsIntro
        case .meetings: L10n.settingsMeetingsIntro
        case .dahliaMCP: L10n.settingsDahliaMCPIntro
        case .workspace: L10n.settingsWorkspaceManagementIntro
        case .backups: L10n.settingsDataProtectionIntro
        default: L10n.thisMacSettingsDescription
        }
    }

    private var canSwitchWorkspace: Bool {
        captionViewModel.canSwitchWorkspace && !WorkspaceAISettingsModel.shared.isSwitchingRuntime
    }

    private func updateCurrentWorkspaceIfNeeded(_ workspace: WorkspaceRecord) {
        guard let currentWorkspace = appSettings.currentWorkspace, currentWorkspace.id == workspace.id else { return }
        let exportFolderChanged = currentWorkspace.path != workspace.path
        appSettings.currentWorkspace = workspace
        guard exportFolderChanged else { return }
        captionViewModel.updateWorkspaceExportFolder(workspace.url)
        sidebarViewModel.refreshCurrentWorkspaceFilesystemServices(workspace)
    }

}
