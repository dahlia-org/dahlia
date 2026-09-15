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
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(SettingsNavigation.visibleSelection(selection).label)
                        .font(.title2)
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
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
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
        case .general, .language, .appearance:
            GeneralSettingsView()
        case .macInference, .modelProvider:
            MacInferenceSettingsView()
        case .accountsAndWorkspaces, .dahliaAccounts:
            Form {
                DahliaAccountsSettingsView(
                    controller: dahliaAccountController,
                    currentWorkspace: appSettings.currentWorkspace,
                    onShowSignIn: mainWindowNavigation.openDahliaSignIn
                )
            }
            .formStyle(.grouped)
            .onChange(of: dahliaAccountController.connections) {
                Task { await workspaceManagementModel.loadWorkspaces() }
            }
        case .workspace:
            Form {
                WorkspaceSettingsView(
                    appDatabase: appDatabase,
                    model: workspaceManagementModel,
                    currentWorkspace: appSettings.currentWorkspace,
                    accountConnections: dahliaAccountController.connections,
                    onUpdateWorkspace: updateCurrentWorkspaceIfNeeded
                )
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
        case .accountPreferences, .aiSummary, .mcp:
            WorkspaceProcessingSettingsView(onOpenMacInference: { selection = .macInference })
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
        case .accountPreferences: L10n.settingsAccountIntro
        case .accountsAndWorkspaces: L10n.settingsAccountsIntro
        case .workspace: L10n.settingsAccountIntro
        case .backups: L10n.backupLocalWorkspacesOnly
        case .macInference: L10n.localModelPreferencesDescription
        case .cloudStorage: L10n.settingsExportIntro
        default: L10n.thisMacSettingsDescription
        }
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
