import AppKit
import SwiftUI

/// Commands that only apply to the selected meeting's generated summary.
struct SummaryTabActions: View {
    @ObservedObject var viewModel: CaptionViewModel

    var body: some View {
        HStack(spacing: 8) {
            ShareSummaryToolbarButton(viewModel: viewModel)

            Menu(L10n.openSummary, systemImage: "arrow.up.forward.app") {
                Button(L10n.openInObsidian, systemImage: "book.closed", action: openInObsidian)
                    .disabled(viewModel.lastSummaryURL == nil || !ObsidianLauncher.isInstalled)

                Button(L10n.openInBrowser, systemImage: "globe", action: openInBrowser)
                    .disabled(viewModel.currentSummaryGoogleFileURL == nil)
            }
            .help(L10n.openSummary)
        }
        .buttonStyle(.bordered)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func openInObsidian() {
        guard let summaryURL = viewModel.lastSummaryURL else { return }
        ObsidianLauncher.open(summaryURL)
    }

    private func openInBrowser() {
        guard let browserURL = viewModel.currentSummaryGoogleFileURL else { return }
        NSWorkspace.shared.open(browserURL)
    }
}
