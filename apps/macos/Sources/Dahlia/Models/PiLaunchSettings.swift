import DahliaRuntimeSupport
import Foundation

/// The environment variables the user adds to every Pi process the account starts, beneath the ones Dahlia sets, so
/// Dahlia's sign-ins and agent directory always win. Secret values stay in the Keychain and never return to the
/// settings screen.
struct PiLaunchSettings: Codable, Equatable, Sendable {
    struct Variable: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        var name: String
        var isSecret = false
        /// nil for a secret, whose value is in the Keychain.
        var value: String?
    }

    var variables: [Variable] = []

    static func defaultsKey(for account: CodexRuntimeProvider) -> String {
        "piLaunch.\(account.accountKey)"
    }

    static func secretKey(for account: CodexRuntimeProvider, id: UUID, profile: DahliaRuntimeProfile = DahliaApplicationSupport.profile()) -> String {
        "piEnvironment.\(profile.rawValue).\(account.accountKey).\(id.uuidString.lowercased())"
    }

    static func load(for account: CodexRuntimeProvider, defaults: UserDefaults = .standard) -> Self {
        defaults.data(forKey: defaultsKey(for: account)).flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
    }

    func save(for account: CodexRuntimeProvider, defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey(for: account))
    }

    /// Deletes the account's secret values from the Keychain when the account signs out or is removed. Blocks on the
    /// Keychain, so call it off MainActor.
    static func removeSecrets(for account: CodexRuntimeProvider, defaults: UserDefaults = .standard) {
        for variable in load(for: account, defaults: defaults).variables where variable.isSecret {
            _ = KeychainService.delete(key: secretKey(for: account, id: variable.id))
        }
    }

    static func isValidName(_ name: String) -> Bool {
        name.wholeMatch(of: /[A-Za-z_][A-Za-z0-9_]*/) != nil
    }

    /// Variables with a valid name and a non-empty value; `secret` reads a secret's value.
    func environment(secret: (UUID) -> String?) -> [String: String] {
        variables.reduce(into: [:]) { environment, variable in
            guard Self.isValidName(variable.name),
                  let value = variable.isSecret ? secret(variable.id) : variable.value,
                  !value.isEmpty
            else { return }
            environment[variable.name] = value
        }
    }
}
