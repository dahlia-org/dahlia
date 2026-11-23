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
    @State private var workspaceDetailsID: UUID?
    @State private var deletingWorkspace: WorkspaceRecord?

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
        .overlay {
            if let workspace = workspaceManagementModel.workspaces.first(where: { $0.id == workspaceDetailsID }) {
                WorkspaceSettingsDetailsView(
                    workspace: workspace,
                    accountName: L10n.localAccount,
                    onClose: { workspaceDetailsID = nil }
                )
            }
        }
        .overlay {
            if let workspace = deletingWorkspace {
                WorkspaceDeletionDialog(
                    workspace: workspace,
                    destinations: workspaceManagementModel.deletionTransferCandidates(for: workspace),
                    onCancel: { deletingWorkspace = nil },
                    onConfirm: { destinationID in
                        await workspaceManagementModel.removeWorkspace(
                            workspace, currentWorkspaceId: appSettings.currentWorkspace?.id, transferringTo: destinationID
                        )
                    }
                )
                .id(workspace.id)
            }
        }
        .scrollContentBackground(.hidden)
        .scrollEdgeEffectHidden()
        .onChange(of: selection) { _, selection in
            workspaceDetailsID = nil
            if selection != .agents { mainWindowNavigation.dismissDahliaSignIn() }
        }
    }

    @ViewBuilder
    private var selectedSettings: some View {
        switch selection {
        case .general, .language:
            GeneralSettingsView()
        case .appearance:
            AppearanceSettingsView()
        case .accountsAndWorkspaces, .dahliaAccounts, .accountPreferences, .macInference, .modelProvider, .aiSummary, .mcp, .agents:
            AgentSettingsView()
        case .workspace, .workspacePreferences:
            WorkspaceSettingsView(
                appDatabase: appDatabase,
                model: workspaceManagementModel,
                currentWorkspace: appSettings.currentWorkspace,
                onShowDetails: { workspaceDetailsID = $0 },
                onRequestDeletion: { deletingWorkspace = $0 },
                onUpdateWorkspace: updateCurrentWorkspaceIfNeeded
            )
        case .providers:
            ProviderAccountsSettingsView()
        case .skills:
            SkillSettingsView()
        case .memory:
            MemorySettingsView()
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
        case .meetings, .transcription, .recordingStopDetection, .liveSubtitles, .screenshots:
            MeetingProcessingSettingsView()
        case .meetingLinks:
            MeetingLinkSettingsView()
        case .dahliaMCP:
            MCPSettingsView(
                workspaces: workspaceManagementModel.workspaces,
                currentWorkspace: appSettings.currentWorkspace
            )
        case .calendar, .eventDisplay:
            CalendarSettingsView()
        case .instructions:
            InstructionsSettingsView(sidebarViewModel: sidebarViewModel)
        case .audioDiagnostics:
            DebugSettingsView()
        }
    }

    private var scopeDescription: String {
        switch SettingsNavigation.visibleSelection(selection) {
        case .accountsAndWorkspaces: L10n.settingsAccountsIntro
        case .agents: L10n.settingsAgentsIntro
        case .skills: L10n.settingsSkillsIntro
        case .memory: L10n.settingsMemoryIntro
        case .meetings: L10n.settingsMeetingsIntro
        case .meetingLinks: L10n.settingsMeetingLinksIntro
        case .dahliaMCP: L10n.settingsDahliaMCPIntro
        case .workspace: L10n.settingsWorkspaceManagementIntro
        case .backups: L10n.settingsDataProtectionIntro
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
