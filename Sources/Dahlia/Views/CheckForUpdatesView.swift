import Sparkle
import SwiftUI

struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button(L10n.checkForUpdates, action: updater.checkForUpdates)
            .disabled(!viewModel.canCheckForUpdates)
    }
}
