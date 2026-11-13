import Foundation

/// Additional disk access for this account's chat on this Mac. Never synchronized to a server.
struct PiFileAccessSettings: Codable, Equatable, Sendable {
    enum Access: String, Codable, CaseIterable, Sendable {
        case readOnly
        case readWrite
    }

    struct Grant: Codable, Equatable, Identifiable, Sendable {
        var id = UUID.v7()
        let path: String
        let isDirectory: Bool
        var access: Access = .readOnly
    }

    var grants: [Grant] = []

    static func defaultsKey(for account: CodexRuntimeProvider) -> String {
        "piFileAccess.\(account.accountKey)"
    }

    static func load(for account: CodexRuntimeProvider, defaults: UserDefaults = .standard) -> Self {
        defaults.data(forKey: defaultsKey(for: account)).flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
    }

    func save(for account: CodexRuntimeProvider, defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey(for: account))
    }

    /// Resolve and validate off MainActor, both when editing and when launching (PATH or symlinks may have changed).
    static func resolved(
        _ grant: Grant,
        searchPath: String,
        home: String = NSHomeDirectory(),
        cwd: URL? = nil,
        environment: [String: String] = [:]
    ) throws -> Grant {
        guard grant.path.hasPrefix("/") else { throw PiRuntimeError.launchFailed(L10n.agentFileAccessNotAllowed) }
        let path = PiSandbox.realPath(URL(fileURLWithPath: grant.path))
        if grant.access == .readWrite {
            let containsCommands = searchPath.split(separator: ":").contains { entry in
                let commandFolder = PiSandbox.realPath(URL(
                    fileURLWithPath: String(entry),
                    relativeTo: cwd.map { URL(fileURLWithPath: $0.path, isDirectory: true) }
                ))
                return path == commandFolder || path.hasPrefix(commandFolder + "/")
                    || (grant.isDirectory && commandFolder.hasPrefix(path + "/"))
            }
            guard PiWorkingDirectory.isAllowed(path, home: PiSandbox.realPath(URL(fileURLWithPath: home))), !containsCommands,
                  try !(PiSandbox.overlapsShellStartupFiles(path, isDirectory: grant.isDirectory, home: home, environment: environment, cwd: cwd))
            else {
                throw PiRuntimeError.launchFailed(L10n.agentFileAccessNotAllowed)
            }
        }
        return Grant(id: grant.id, path: path, isDirectory: grant.isDirectory, access: grant.access)
    }
}
