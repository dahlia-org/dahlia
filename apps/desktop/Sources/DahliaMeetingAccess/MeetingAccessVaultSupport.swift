import DahliaRuntimeSupport
import Foundation

/// Vault を跨いで書き込みを行うストアが共有する土台。
/// Project 変更と Summary 更新はどちらもこのロックと `vault:` URL 表現を使う。
extension MeetingAccessStore {
    func requireWriteAccess() throws {
        guard allowsWrites else { throw MeetingAccessError.writeAccessRequired }
    }

    func withVaultMutationLock<T>(vaultURL: URL?, operation: () throws -> T) throws -> T {
        guard let vaultURL else { return try operation() }
        do {
            return try DahliaVaultMutationLock.withLock(
                vaultURL: vaultURL,
                vaultID: vaultID,
                operation: operation
            )
        } catch is DahliaVaultMutationLockError {
            throw MeetingAccessError.workspaceBusy
        }
    }

    /// `summary_exports.url` に保存される Vault 相対パス表現を読み解く。
    func vaultRelativeSummaryPath(_ value: String) -> String? {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "vault",
              components.host?.isEmpty != false else { return nil }
        let path = String(components.path.drop(while: { $0 == "/" }))
        return path.isEmpty ? nil : path
    }

    func vaultSummaryURL(_ relativePath: String) -> String {
        var components = URLComponents()
        components.scheme = "vault"
        components.host = ""
        components.path = "/" + relativePath
        return components.string ?? "vault:///\(relativePath)"
    }

    func isInsideVault(_ value: URL, vaultURL: URL) -> Bool {
        let rootPath = vaultURL.resolvingSymlinksInPath().standardizedFileURL.path
        let valuePath = value.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return valuePath.hasPrefix(prefix)
    }
}
