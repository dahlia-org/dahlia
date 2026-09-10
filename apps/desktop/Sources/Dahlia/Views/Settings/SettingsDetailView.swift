import SwiftUI

struct SettingsDetailView: View {
    @Environment(MainWindowNavigation.self) private var mainWindowNavigation
    @Binding var selection: SettingsCategory
    var captionViewModel: CaptionViewModel
    var sidebarViewModel: SidebarViewModel
    let appDatabase: AppDatabaseManager?
    var vaultManagementModel: VaultManagementModel
    let onShowUnprocessedRecordings: (UUID) -> Void

    @ObservedObject private var appSettings = AppSettings.shared
    @State private var settingsAccountID: UUID?
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
        .onChange(of: appSettings.currentVault?.accountConnectionId, initial: true) { _, connectionID in
            settingsAccountID = connectionID
        }
        .onChange(of: selection) { _, selection in
            if selection != .accountsAndVaults { mainWindowNavigation.dismissDahliaSignIn() }
        }
    }

    @ViewBuilder
    private var selectedSettings: some View {
        switch selection {
        case .general, .language, .appearance:
            GeneralSettingsView()
        case .macInference, .modelProvider:
            MacInferenceSettingsView()
        case .accountsAndVaults, .dahliaAccounts, .vault:
            AccountsAndVaultsSettingsView(
                appDatabase: appDatabase,
                vaultModel: vaultManagementModel,
                currentVault: appSettings.currentVault,
                accountController: dahliaAccountController,
                onShowSignIn: mainWindowNavigation.openDahliaSignIn,
                onUpdateVault: updateCurrentVaultIfNeeded
            )
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
            AccountProcessingSettingsView(
                connectionID: $settingsAccountID,
                onOpenMacInference: { selection = .macInference },
                onOpenLanguageSettings: { selection = .general }
            )
        case .transcription:
            TranscriptionSettingsView(onOpenAccountSettings: {
                settingsAccountID = appSettings.currentVault?.accountConnectionId
                selection = .accountPreferences
            })
        case .liveSubtitles:
            LiveSubtitleSettingsView()
        case .screenshots:
            ScreenshotSettingsView(onOpenLanguageSettings: { selection = .general })
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
        case .accountsAndVaults: L10n.settingsAccountsIntro
        case .backups: L10n.backupLocalVaultsOnly
        case .macInference: L10n.localModelPreferencesDescription
        case .cloudStorage: L10n.settingsExportIntro
        default: L10n.thisMacSettingsDescription
        }
    }

    private func updateCurrentVaultIfNeeded(_ vault: VaultRecord) {
        guard let currentVault = appSettings.currentVault, currentVault.id == vault.id else { return }
        let exportFolderChanged = currentVault.path != vault.path
        appSettings.currentVault = vault
        guard exportFolderChanged else { return }
        captionViewModel.updateVaultExportFolder(vault.url)
        sidebarViewModel.refreshCurrentVaultFilesystemServices(vault)
    }

}
