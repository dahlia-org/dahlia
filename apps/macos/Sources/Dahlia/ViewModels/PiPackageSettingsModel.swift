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
    private(set) var changeSucceeded = false
    /// The plugin an install or removal is running for.
    private(set) var changingSource: String?
    private(set) var errorMessage: String?
    private(set) var errorDetails: String?
    private(set) var didChange = false
    private let service: PiPackageService
    private let changePackage: @Sendable (String, Bool) async throws -> Void

    init(
        service: PiPackageService = .shared,
        changePackage: (@Sendable (String, Bool) async throws -> Void)? = nil
    ) {
        self.service = service
        self.changePackage = changePackage ?? { try await service.change($0, installing: $1) }
    }

    var canInstall: Bool { !isBusy && (try? PiPackageService.source(source)) != nil }

    func refresh() async {
        do {
            isAutoReviewInstalled = await service.isAutoReviewInstalled()
            isWebAccessInstalled = await service.isWebAccessInstalled()
            packages = try await service.packages()
        } catch {
            if errorMessage == nil { errorMessage = error.localizedDescription }
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
        changeSucceeded = false
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
                try await changePackage(source, installing)
                changeSucceeded = true
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
