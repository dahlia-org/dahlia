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
    @State private var dahliaAccountController = DahliaCloudAccountController.shared

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    EmptyView()
                } header: {
                    HStack {
                        Text(selection.label)
                            .font(.title2)
                            .foregroundStyle(DahliaDesign.primaryTextColor)
                            .accessibilityAddTraits(.isHeader)

                        Spacer()

                        if selection == .general {
                            Button(L10n.initialSetup, action: mainWindowNavigation.openSetupTour)
                                .buttonStyle(.dahlia(.primary))
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: 64)
            .padding(.top, DahliaDesign.windowHeaderHeight)

            selectedSettings
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: selection) { _, selection in
            if selection != .accountsAndVaults { mainWindowNavigation.dismissDahliaSignIn() }
        }
    }

    @ViewBuilder
    private var selectedSettings: some View {
        switch selection {
        case .general:
            GeneralSettingsView()
        case .accountsAndVaults, .dahliaAccounts, .vault:
            AccountsAndVaultsSettingsView(
                appDatabase: appDatabase,
                vaultModel: vaultManagementModel,
                currentVault: appSettings.currentVault,
                accountController: dahliaAccountController,
                onShowSignIn: mainWindowNavigation.openDahliaSignIn,
                onUpdateVault: updateCurrentVaultIfNeeded,
                onUpdateCurrentVaultAccount: updateCurrentVaultAccountIfNeeded
            )
        case .language:
            LanguageSettingsView()
        case .appearance:
            AppearanceSettingsView()
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
            ScreenshotSettingsView(onOpenLanguageSettings: { selection = .language })
        case .calendar:
            CalendarSettingsView()
        case .cloudStorage:
            CloudStorageSettingsView()
        case .modelProvider:
            AccountSettingsView()
        case .aiSummary, .mcp:
            AISummarySettingsView()
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

    private func updateCurrentVaultIfNeeded(_ vault: VaultRecord) {
        guard appSettings.currentVault?.id == vault.id else { return }
        appSettings.currentVault = vault
    }

    private func updateCurrentVaultAccountIfNeeded(_ vault: VaultRecord) {
        guard appSettings.currentVault?.id == vault.id else { return }
        appSettings.currentVault = vault
        VaultAISettingsModel.shared.activate(vault: vault)
    }

}
