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
                GeneralSettingsView(sidebarViewModel: sidebarViewModel, onSelectVault: onSelectVault)
            case .backups:
                BackupSettingsView(
                    dbQueue: sidebarViewModel.dbQueue,
                    captionViewModel: captionViewModel,
                    sidebarViewModel: sidebarViewModel
                )
            case .transcription:
                TranscriptionSettingsView()
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
            case .instructions:
                InstructionsSettingsView(sidebarViewModel: sidebarViewModel)
            case .developer:
                DeveloperSettingsView()
            case .audioDiagnostics:
                DebugSettingsView()
            }
        }
        .navigationTitle(selection.label)
    }
}
