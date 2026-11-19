import Foundation
import Observation

@MainActor
@Observable
final class PiPackageSettingsModel {
    var source = ""
    private(set) var packages: [String] = []
    private(set) var isAutoReviewInstalled = false
    private(set) var isWebAccessInstalled = false
    private(set) var isBusy = false
    /// The plugin an install or removal is running for.
    private(set) var changingSource: String?
    private(set) var errorMessage: String?
    private(set) var errorDetails: String?
    private(set) var didChange = false
    let account: CodexRuntimeProvider
    private let service: PiPackageService

    init(account: CodexRuntimeProvider, service: PiPackageService = .shared) {
        self.account = account
        self.service = service
    }

    var canInstall: Bool { !isBusy && (try? PiPackageService.source(source)) != nil }

    func refresh() async {
        do {
            isAutoReviewInstalled = await service.isAutoReviewInstalled(for: account)
            isWebAccessInstalled = await service.isWebAccessInstalled(for: account)
            packages = try await service.packages(for: account)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func install() {
        change(source, installing: true)
    }

    func installAutoReview() {
        change(AgentAutoReviewSettings.packageSource, installing: true)
    }

    func installWebAccess() {
        change(AgentWebAccessSettings.packageSource, installing: true)
    }

    func remove(_ source: String) {
        change(source, installing: false)
    }

    private func change(_ source: String, installing: Bool) {
        guard !isBusy else { return }
        isBusy = true
        changingSource = source
        errorMessage = nil
        errorDetails = nil
        // An accepted installation finishes even when its settings tab is hidden.
        Task {
            defer {
                isBusy = false
                changingSource = nil
            }
            do {
                try await service.change(source, installing: installing, account: account)
                if installing, source == self.source { self.source = "" }
                didChange = true
                NotificationCenter.default.post(name: PiPackageService.packagesDidChange, object: nil)
            } catch {
                errorMessage = error.localizedDescription
                if case let PiPackageService.PackageError.commandFailed(detail) = error {
                    errorDetails = detail
                }
            }
            await refresh()
        }
    }
}
