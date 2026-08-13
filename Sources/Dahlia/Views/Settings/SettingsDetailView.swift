import SwiftUI

struct SettingsDetailView: View {
    let selection: SettingsCategory
    var captionViewModel: CaptionViewModel
    var sidebarViewModel: SidebarViewModel
    let appDatabase: AppDatabaseManager?
    var vaultManagementModel: VaultManagementModel
    var onSelectVault: (VaultRecord) -> Void

    var body: some View {
        Group {
            switch selection {
            case .general:
                GeneralSettingsView()
            case .vault:
                VaultSettingsView(
                    appDatabase: appDatabase,
                    model: vaultManagementModel,
                    currentVault: sidebarViewModel.currentVault,
                    canSwitchVault: captionViewModel.canSwitchVault,
                    onSelectVault: onSelectVault
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
            case .aiSummary:
                AISummarySettingsView()
            case .mcp:
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
        .navigationTitle(selection.label)
    }
}
