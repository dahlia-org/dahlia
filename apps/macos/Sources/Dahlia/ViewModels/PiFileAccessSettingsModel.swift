import Foundation
import Observation

@MainActor
@Observable
final class PiFileAccessSettingsModel {
    private(set) var settings: PiFileAccessSettings
    private(set) var isUpdating = false
    private(set) var defaultAccess = PiSandbox.DefaultFileAccess()
    var errorMessage: String?
    private let defaults: UserDefaults
    private let secret: @Sendable (String) -> String?

    init(
        defaults: UserDefaults = .standard,
        secret: @escaping @Sendable (String) -> String? = { KeychainService.load(key: $0) }
    ) {
        self.defaults = defaults
        self.secret = secret
        settings = PiFileAccessSettings.load(defaults: defaults)
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

    func refreshDefaults(workingDirectory: String) async {
        do {
            let paths = try await Task.detached {
                let path = workingDirectory.trimmingCharacters(in: .whitespaces).nilIfBlank ?? PiWorkingDirectory.defaultPath
                let cwd = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
                return try PiSandbox.defaultFileAccess(cwd: cwd, agentURL: PiAgentDirectoryLocator().agentURL())
            }.value
            guard !Task.isCancelled else { return }
            defaultAccess = paths
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
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
        settings = PiFileAccessSettings.load(defaults: defaults)
        settings.grants.removeAll { $0.id == id }
        settings.save(defaults: defaults)
        errorMessage = nil
    }

    private func update(_ change: @escaping @Sendable (inout PiFileAccessSettings, String, URL, [String: String]) throws -> Void) async {
        guard !isUpdating else { return }
        isUpdating = true
        errorMessage = nil
        defer { isUpdating = false }
        let snapshot = PiFileAccessSettings.load(defaults: defaults)
        let secret = secret
        let securityVariables = CommandLineToolLocator.discoveryEnvironmentNames + ["HOME", "ZDOTDIR", "XDG_CONFIG_HOME", "BASH_ENV", "ENV"]
        let launch = PiLaunchSettings(variables: PiLaunchSettings.load(defaults: defaults).variables.filter {
            securityVariables.contains($0.name)
        })
        let workPath = defaults.string(forKey: PiWorkingDirectory.defaultsKey())?
            .trimmingCharacters(in: .whitespaces).nilIfBlank ?? PiWorkingDirectory.defaultPath
        do {
            let updated = try await Task.detached {
                var updated = snapshot
                let environment = ProcessInfo.processInfo.environment.merging(launch.resolvedEnvironment(secret: secret)) { $1 }
                let pi = (try? PiBundle.executableURL()) ?? URL(fileURLWithPath: "/bin/sh")
                let cwd = URL(fileURLWithPath: (workPath as NSString).expandingTildeInPath, isDirectory: true)
                try change(&updated, CommandLineToolLocator.searchPath(for: pi, environment: environment), cwd, environment)
                return updated
            }.value
            let current = PiFileAccessSettings.load(defaults: defaults)
            guard current == snapshot else {
                settings = current
                errorMessage = L10n.agentFileAccessChanged
                return
            }
            settings = updated
            settings.save(defaults: defaults)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
