import SwiftUI

struct SettingsDetailView: View {
    let selection: SettingsCategory
    var captionViewModel: CaptionViewModel
    var sidebarViewModel: SidebarViewModel
    let appDatabase: AppDatabaseManager?
    var vaultManagementModel: VaultManagementModel

    @ObservedObject private var appSettings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    EmptyView()
                } header: {
                    Text(selection.label)
                        .dahliaFont(.displayTitle)
                        .foregroundStyle(.primary)
                        .accessibilityAddTraits(.isHeader)
                }
            }
            .formStyle(.grouped)
            .frame(height: 64)

            selectedSettings
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var selectedSettings: some View {
        switch selection {
        case .general:
            GeneralSettingsView()
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
                captionViewModel: captionViewModel
            )
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
