import SwiftUI

struct SettingsDetailView: View {
    let selection: SettingsCategory
    var captionViewModel: CaptionViewModel
    var sidebarViewModel: SidebarViewModel
    var onSelectVault: (VaultRecord) -> Void

    var body: some View {
        Group {
            switch selection {
            case .general:
                GeneralAndBackupSettingsView(
                    captionViewModel: captionViewModel,
                    sidebarViewModel: sidebarViewModel,
                    onSelectVault: onSelectVault
                )
            case .permissions:
                PermissionSettingsView()
            case .transcription:
                TranscriptionAndSubtitleSettingsView()
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
                MCPSettingsView()
            case .betaFeatures:
                BetaFeaturesSettingsView()
            case .developer:
                DeveloperAndDiagnosticsSettingsView()
            }
        }
        .navigationTitle(selection.label)
    }
}
