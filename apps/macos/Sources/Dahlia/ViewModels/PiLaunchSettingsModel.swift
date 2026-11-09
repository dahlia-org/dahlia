import Foundation
import Observation

/// Edits the environment variables the account's Pi processes get. Every change is saved at once and applies to Pi
/// processes started afterward. A secret's value goes to the Keychain, off MainActor, and is never read back.
@MainActor
@Observable
final class PiLaunchSettingsModel {
    let account: CodexRuntimeProvider
    private(set) var settings: PiLaunchSettings
    /// Secrets with a stored value, so the field can show that one is saved without reading it.
    private(set) var storedSecretIDs: Set<UUID> = []

    private let defaults: UserDefaults
    private let secrets: Secrets

    /// The Keychain by default; tests use memory.
    struct Secrets: Sendable {
        var load: @Sendable (String) -> String?
        var save: @Sendable (String, String) throws -> Void
        var delete: @Sendable (String) -> Void

        static let keychain = Self(
            load: { KeychainService.load(key: $0) },
            save: { try KeychainService.save(key: $0, value: $1) },
            delete: { _ = KeychainService.delete(key: $0) }
        )
    }

    init(account: CodexRuntimeProvider, defaults: UserDefaults = .standard, secrets: Secrets = .keychain) {
        self.account = account
        self.defaults = defaults
        self.secrets = secrets
        settings = PiLaunchSettings.load(for: account, defaults: defaults)
    }

    /// Checks which secrets have a stored value, without returning the values.
    func refreshStoredSecrets() async {
        let keys = settings.variables.filter(\.isSecret).map { ($0.id, secretKey($0.id)) }
        let secrets = secrets
        storedSecretIDs = await Task.detached {
            Set(keys.filter { secrets.load($0.1) != nil }.map(\.0))
        }.value
    }

    func addVariable() {
        settings.variables.append(.init(id: .v7(), name: "", value: ""))
        save()
    }

    func setName(_ name: String, of id: UUID) {
        update(id) { $0.name = name }
    }

    func setValue(_ value: String, of id: UUID) {
        update(id) { $0.value = value }
    }

    /// Replaces a secret's stored value; an empty value leaves it as it is.
    func setSecretValue(_ value: String, of id: UUID) async throws {
        guard !value.isEmpty, settings.variables.contains(where: { $0.id == id && $0.isSecret }) else { return }
        try await saveSecret(value, id)
        storedSecretIDs.insert(id)
    }

    /// Making a value secret moves it to the Keychain; making it plain again clears it, since a secret is never read back.
    func setSecret(_ isSecret: Bool, of id: UUID) async throws {
        guard let variable = settings.variables.first(where: { $0.id == id }), variable.isSecret != isSecret else { return }
        if isSecret {
            if let value = variable.value, !value.isEmpty {
                try await saveSecret(value, id)
                storedSecretIDs.insert(id)
            }
            update(id) {
                $0.isSecret = true
                $0.value = nil
            }
        } else {
            await deleteSecret(id)
            update(id) {
                $0.isSecret = false
                $0.value = ""
            }
        }
    }

    func removeVariable(_ id: UUID) async {
        settings.variables.removeAll { $0.id == id }
        save()
        await deleteSecret(id)
    }

    private func update(_ id: UUID, _ change: (inout PiLaunchSettings.Variable) -> Void) {
        guard let index = settings.variables.firstIndex(where: { $0.id == id }) else { return }
        change(&settings.variables[index])
        save()
    }

    private func saveSecret(_ value: String, _ id: UUID) async throws {
        let (secrets, key) = (secrets, secretKey(id))
        try await Task.detached { try secrets.save(key, value) }.value
    }

    private func deleteSecret(_ id: UUID) async {
        storedSecretIDs.remove(id)
        let (secrets, key) = (secrets, secretKey(id))
        await Task.detached { secrets.delete(key) }.value
    }

    private func secretKey(_ id: UUID) -> String {
        PiLaunchSettings.secretKey(for: account, id: id)
    }

    private func save() {
        settings.save(for: account, defaults: defaults)
    }
}
