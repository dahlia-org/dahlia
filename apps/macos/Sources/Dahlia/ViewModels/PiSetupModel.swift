import Foundation
import Observation

@MainActor
@Observable
final class PiSetupModel {
    private(set) var hasManagedPi = false
    private(set) var isCheckingInstallation = true
    private(set) var isReady = false
    private(set) var errorMessage: String?
    private let account: CodexRuntimeProvider
    private let defaults: UserDefaults

    init(account: CodexRuntimeProvider, defaults: UserDefaults = .standard) {
        self.account = account
        self.defaults = defaults
    }

    func refresh(
        managedPiExists: () async -> Bool = {
            await Task.detached {
                CommandLineToolLocator.isExecutableFile(atPath: PiInstaller.executableURL.path)
            }.value
        }
    ) async {
        let installed = await managedPiExists()
        guard !Task.isCancelled else { return }
        hasManagedPi = installed
        isReady = installed && PiBundle.usesManagedPi(for: account, defaults: defaults)
        isCheckingInstallation = false
    }

    func install(
        installPi: () async throws -> Void = {
            let release = try await PiInstaller.release()
            try Task.checkCancellation()
            try await PiInstaller.install(release)
        }
    ) async {
        errorMessage = nil
        do {
            if !hasManagedPi { try await installPi() }
            try Task.checkCancellation()
            defaults.set(true, forKey: PiBundle.useManagedPiDefaultsKey(for: account))
            hasManagedPi = true
            isReady = true
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }
}
