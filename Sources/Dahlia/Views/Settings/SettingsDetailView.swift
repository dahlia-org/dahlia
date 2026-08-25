import SwiftUI

struct SettingsDetailView: View {
    @Binding var selection: SettingsCategory
    var captionViewModel: CaptionViewModel
    var sidebarViewModel: SidebarViewModel
    let appDatabase: AppDatabaseManager?
    var vaultManagementModel: VaultManagementModel
    let onShowUnprocessedRecordings: (UUID) -> Void

    @ObservedObject private var appSettings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    EmptyView()
                } header: {
                    Text(selection.label)
                        .font(.title2)
                        .foregroundStyle(DahliaDesign.primaryTextColor)
                        .accessibilityAddTraits(.isHeader)
                }
            }
            .formStyle(.grouped)
            .frame(height: 64)
            .padding(.top, DahliaDesign.windowHeaderHeight)

            selectedSettings
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var selectedSettings: some View {
        switch selection {
        case .general:
            GeneralSettingsView()
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
}
