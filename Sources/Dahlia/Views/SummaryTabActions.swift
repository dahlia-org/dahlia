import AppKit
import SwiftUI

/// External destinations for the selected meeting's generated summary.
struct SummaryOpenMenu: View {
    @ObservedObject var viewModel: CaptionViewModel

    var body: some View {
        Menu(L10n.openSummary, systemImage: "arrow.up.forward.app") {
            Button(L10n.openInObsidian, systemImage: "book.closed", action: openInObsidian)
                .disabled(viewModel.lastSummaryURL == nil || !ObsidianLauncher.isInstalled)

            Button(L10n.openInBrowser, systemImage: "globe", action: openInBrowser)
                .disabled(viewModel.currentSummaryGoogleFileURL == nil)
        }
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
