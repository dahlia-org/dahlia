import Observation

@MainActor
@Observable
final class CustomerIntelligenceNavigationHistoryBridge {
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    @ObservationIgnored private weak var model: CustomerIntelligenceWorkspaceViewModel?

    func connect(_ model: CustomerIntelligenceWorkspaceViewModel) {
        self.model = model
        refresh()
    }

    func disconnect(_ model: CustomerIntelligenceWorkspaceViewModel) {
        guard self.model === model else { return }
        self.model = nil
        canGoBack = false
        canGoForward = false
    }

    func refresh() {
        canGoBack = model?.canGoBack ?? false
        canGoForward = model?.canGoForward ?? false
    }

    func goBack() {
        guard let model else { return }
        Task {
            await model.goBack()
            refresh()
        }
    }

    func goForward() {
        guard let model else { return }
        Task {
            await model.goForward()
            refresh()
        }
    }
}
