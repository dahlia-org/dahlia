import Foundation
import Observation

@MainActor
@Observable
final class PiPackageSettingsModel {
    var source = ""
    private(set) var packages: [String] = []
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    private(set) var errorDetails: String?
    private(set) var didChange = false
    private let account: CodexRuntimeProvider
    private let service: PiPackageService

    init(account: CodexRuntimeProvider, service: PiPackageService = .shared) {
        self.account = account
        self.service = service
    }

    var canInstall: Bool { !isBusy && (try? PiPackageService.source(source)) != nil }

    func refresh() async {
        do {
            packages = try await service.packages(for: account)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func install() {
        change(source, installing: true)
    }

    func remove(_ source: String) {
        change(source, installing: false)
    }

    private func change(_ source: String, installing: Bool) {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        errorDetails = nil
        // An accepted installation finishes even when its settings tab is hidden.
        Task {
            defer { isBusy = false }
            do {
                try await service.change(source, installing: installing, account: account)
                if installing { self.source = "" }
                didChange = true
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
