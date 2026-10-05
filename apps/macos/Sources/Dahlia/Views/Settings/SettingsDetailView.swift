import SwiftUI

struct SettingsDetailView: View {
    @Environment(MainWindowNavigation.self) private var mainWindowNavigation
    @Binding var selection: SettingsCategory
    var captionViewModel: CaptionViewModel
    var sidebarViewModel: SidebarViewModel
    let appDatabase: AppDatabaseManager?
    var workspaceManagementModel: WorkspaceManagementModel
    let onSelectWorkspace: (WorkspaceRecord) -> Void
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
                                .font(.title2)
                                .foregroundStyle(.primary)
                                .accessibilityAddTraits(.isHeader)
                            Text(scopeDescription)
                                .font(.callout)
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
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: 90)
            .padding(.top, DahliaDesign.windowHeaderHeight)

            selectedSettings
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: selection) { _, selection in
            if selection != .accountsAndWorkspaces { mainWindowNavigation.dismissDahliaSignIn() }
        }
    }

    @ViewBuilder
    private var selectedSettings: some View {
        switch selection {
        case .general, .language, .appearance, .recordingStopDetection:
            GeneralSettingsView()
        case .accountsAndWorkspaces, .dahliaAccounts, .accountPreferences, .macInference, .modelProvider, .aiSummary, .mcp:
            Form {
                DahliaAccountsSettingsView(
                    controller: dahliaAccountController,
                    currentWorkspace: appSettings.currentWorkspace,
                    workspaces: workspaceManagementModel.workspaces,
                    canSwitchAccount: canSwitchWorkspace,
                    onSelectWorkspace: onSelectWorkspace,
                    onShowSignIn: mainWindowNavigation.openDahliaSignIn
                )
                Group {
                    if appSettings.currentWorkspace != nil, WorkspaceAISettingsModel.shared.isLocalAccount {
                        AccountSettingsView()
                    }
                    AccountProcessingSettingsView()
                }
                .id(appSettings.currentWorkspace?.accountConnectionId)
            }
            .formStyle(.grouped)
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
                    onSelectWorkspace: onSelectWorkspace,
                    onUpdateWorkspace: updateCurrentWorkspaceIfNeeded
                )
                WorkspaceProcessingSettingsView()
            }
            .formStyle(.grouped)
            .onChange(of: workspaceManagementModel.workspaces.map { "\($0.id):\($0.accountConnectionId?.uuidString ?? "local")" }) {
                Task { await dahliaAccountController.reload() }
            }
        case .permissions:
            PermissionSettingsView()
        case .backups:
            BackupSettingsView(
                dbQueue: sidebarViewModel.dbQueue,
                captionViewModel: captionViewModel,
                onShowUnprocessedRecordings: onShowUnprocessedRecordings
            )
        case .search:
            SearchSettingsView(database: appDatabase)
        case .transcription:
            TranscriptionSettingsView()
        case .liveSubtitles:
            LiveSubtitleSettingsView()
        case .screenshots:
            ScreenshotSettingsView()
        case .calendar:
            CalendarSettingsView()
        case .cloudStorage:
            CloudStorageSettingsView()
        case .instructions:
            InstructionsSettingsView(sidebarViewModel: sidebarViewModel)
        case .betaFeatures:
            BetaFeaturesSettingsView()
        case .developer:
            DeveloperSettingsView()
        case .audioDiagnostics:
            DebugSettingsView()
        }
    }

    private var scopeDescription: String {
        switch SettingsNavigation.visibleSelection(selection) {
        case .accountsAndWorkspaces: L10n.settingsAccountsIntro
        case .workspace: L10n.settingsWorkspaceManagementIntro
        case .backups: L10n.backupLocalWorkspacesOnly
        case .cloudStorage: L10n.settingsExportIntro
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
