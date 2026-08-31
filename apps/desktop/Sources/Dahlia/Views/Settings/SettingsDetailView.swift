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
            if selection != .general { dismissDahliaSignIn() }
        }
    }

    @ViewBuilder
    private var selectedSettings: some View {
        switch selection {
        case .general:
            GeneralSettingsView(
                dahliaAccountController: dahliaAccountController,
                onShowDahliaSignIn: showDahliaSignIn,
                onCancelDahliaSignIn: dahliaAccountController.cancelAccountTask,
                onDahliaSignOut: signOutOfDahlia
            )
        case .language:
            LanguageSettingsView()
        case .appearance:
            AppearanceSettingsView()
        case .vault:
            VaultSettingsView(
                appDatabase: appDatabase,
                model: vaultManagementModel,
                currentVault: appSettings.currentVault,
                onRenameVault: updateCurrentVaultIfNeeded
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

    private func showDahliaSignIn() {
        mainWindowNavigation.openDahliaSignIn()
    }

    private func dismissDahliaSignIn() {
        mainWindowNavigation.dismissDahliaSignIn()
    }

    private func signOutOfDahlia() {
        dahliaAccountController.startSignOut()
    }
}
