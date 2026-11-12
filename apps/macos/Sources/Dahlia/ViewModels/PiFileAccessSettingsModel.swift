import Foundation
import Observation

@MainActor
@Observable
final class PiFileAccessSettingsModel {
    let account: CodexRuntimeProvider
    private(set) var settings: PiFileAccessSettings
    private(set) var isUpdating = false
    var errorMessage: String?
    private let defaults: UserDefaults
    private let secret: @Sendable (String) -> String?

    init(
        account: CodexRuntimeProvider,
        defaults: UserDefaults = .standard,
        secret: @escaping @Sendable (String) -> String? = { KeychainService.load(key: $0) }
    ) {
        self.account = account
        self.defaults = defaults
        self.secret = secret
        settings = PiFileAccessSettings.load(for: account, defaults: defaults)
    }

    func add(_ urls: [URL]) async {
        await update { settings, searchPath, cwd, environment in
            for url in urls {
                let path = PiSandbox.realPath(url)
                let isDirectory = try URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                let grant = try PiFileAccessSettings.resolved(
                    .init(path: path, isDirectory: isDirectory),
                    searchPath: searchPath,
                    cwd: cwd,
                    environment: environment
                )
                if !settings.grants.contains(where: { $0.path == path }) { settings.grants.append(grant) }
            }
        }
    }

    func setAccess(_ access: PiFileAccessSettings.Access, for id: UUID) async {
        await update { settings, searchPath, cwd, environment in
            guard let index = settings.grants.firstIndex(where: { $0.id == id }) else { return }
            settings.grants[index].access = access
            settings.grants[index] = try PiFileAccessSettings.resolved(
                settings.grants[index],
                searchPath: searchPath,
                cwd: cwd,
                environment: environment
            )
        }
    }

    func remove(_ id: UUID) {
        settings = PiFileAccessSettings.load(for: account, defaults: defaults)
        settings.grants.removeAll { $0.id == id }
        settings.save(for: account, defaults: defaults)
        errorMessage = nil
    }

    private func update(_ change: @escaping @Sendable (inout PiFileAccessSettings, String, URL, [String: String]) throws -> Void) async {
        guard !isUpdating else { return }
        isUpdating = true
        errorMessage = nil
        defer { isUpdating = false }
        let snapshot = PiFileAccessSettings.load(for: account, defaults: defaults)
        let account = account
        let secret = secret
        let securityVariables = ["PATH", "HOME", "ZDOTDIR", "XDG_CONFIG_HOME", "BASH_ENV", "ENV"]
        let launch = PiLaunchSettings(variables: PiLaunchSettings.load(for: account, defaults: defaults).variables.filter {
            securityVariables.contains($0.name)
        })
        let workPath = defaults.string(forKey: PiWorkingDirectory.defaultsKey(for: account))?
            .trimmingCharacters(in: .whitespaces).nilIfBlank ?? PiWorkingDirectory.defaultPath
        do {
            let updated = try await Task.detached {
                var updated = snapshot
                let environment = ProcessInfo.processInfo.environment.merging(launch.resolvedEnvironment(for: account, secret: secret)) { $1 }
                let pi = (try? PiBundle.executableURL(for: account)) ?? URL(fileURLWithPath: "/bin/sh")
                let cwd = URL(fileURLWithPath: (workPath as NSString).expandingTildeInPath, isDirectory: true)
                try change(&updated, CommandLineToolLocator.searchPath(for: pi, environment: environment), cwd, environment)
                return updated
            }.value
            let current = PiFileAccessSettings.load(for: account, defaults: defaults)
            guard current == snapshot else {
                settings = current
                errorMessage = L10n.agentFileAccessChanged
                return
            }
            settings = updated
            settings.save(for: account, defaults: defaults)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
