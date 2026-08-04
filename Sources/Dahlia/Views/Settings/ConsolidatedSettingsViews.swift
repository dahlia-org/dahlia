import SwiftUI

struct GeneralAndBackupSettingsView: View {
    var captionViewModel: CaptionViewModel
    var sidebarViewModel: SidebarViewModel
    var onSelectVault: (VaultRecord) -> Void

    var body: some View {
        ConsolidatedSettingsPages(primaryLabel: L10n.general, secondaryLabel: L10n.backups) {
            GeneralSettingsView(sidebarViewModel: sidebarViewModel, onSelectVault: onSelectVault)
        } secondary: {
            BackupSettingsView(
                dbQueue: sidebarViewModel.dbQueue,
                captionViewModel: captionViewModel,
                sidebarViewModel: sidebarViewModel
            )
        }
    }
}

struct TranscriptionAndSubtitleSettingsView: View {
    var body: some View {
        ConsolidatedSettingsPages(primaryLabel: L10n.transcription, secondaryLabel: L10n.liveSubtitles) {
            TranscriptionSettingsView()
        } secondary: {
            LiveSubtitleSettingsView()
        }
    }
}

struct DeveloperAndDiagnosticsSettingsView: View {
    var body: some View {
        ConsolidatedSettingsPages(primaryLabel: L10n.developerSettings, secondaryLabel: L10n.diagnostics) {
            DeveloperSettingsView()
        } secondary: {
            DebugSettingsView()
        }
    }
}

private struct ConsolidatedSettingsPages<Primary: View, Secondary: View>: View {
    enum Page {
        case primary
        case secondary
    }

    let primaryLabel: String
    let secondaryLabel: String
    @ViewBuilder let primary: () -> Primary
    @ViewBuilder let secondary: () -> Secondary
    @State private var page = Page.primary

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $page) {
                Text(primaryLabel).tag(Page.primary)
                Text(secondaryLabel).tag(Page.secondary)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
            .padding(12)

            switch page {
            case .primary:
                primary()
            case .secondary:
                secondary()
            }
        }
    }
}
