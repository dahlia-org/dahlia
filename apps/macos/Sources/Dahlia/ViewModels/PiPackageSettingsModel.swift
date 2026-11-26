import Foundation
import Observation

@MainActor
@Observable
final class PiPackageSettingsModel {
    var source = ""
    private(set) var packages: [String] = []
    private(set) var isWebAccessInstalled = false
    private(set) var isBusy = false
    private(set) var changeSucceeded = false
    /// The plugin an install or removal is running for.
    private(set) var changingSource: String?
    private(set) var errorMessage: String?
    private(set) var errorDetails: String?
    private(set) var didChange = false
    private var commandRevision = 0
    private let service: PiPackageService
    private let loadPackages: @Sendable () async throws -> [String]
    private let changePackage: @Sendable (String, Bool) async throws -> Void

    init(
        service: PiPackageService = .shared,
        loadPackages: (@Sendable () async throws -> [String])? = nil,
        changePackage: (@Sendable (String, Bool) async throws -> Void)? = nil
    ) {
        self.service = service
        self.loadPackages = loadPackages ?? { try await service.packages() }
        self.changePackage = changePackage ?? { try await service.change($0, installing: $1) }
    }

    var canInstall: Bool { !isBusy && (try? PiPackageService.source(source)) != nil }

    func refresh(preservingCommandError: Bool = false) async {
        let revision = commandRevision
        do {
            isWebAccessInstalled = await service.isWebAccessInstalled()
            packages = try await loadPackages()
        } catch {
            if revision == commandRevision, !preservingCommandError {
                errorMessage = error.localizedDescription
                errorDetails = nil
            }
        }
    }

    func install() {
        change(source, installing: true)
    }

    func installWebAccess() {
        change(AgentWebAccessSettings.packageSource, installing: true)
    }

    func remove(_ source: String) {
        change(source, installing: false)
    }

    private func change(_ source: String, installing: Bool) {
        guard !isBusy else { return }
        commandRevision += 1
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
            // Reads started before or during the command cannot replace its result.
            commandRevision += 1
            await refresh(preservingCommandError: !changeSucceeded)
        }
    }
}
