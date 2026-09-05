enum MCPVaultDisplayName {
    static func resolve(for vault: VaultRecord, among vaults: [VaultRecord]) -> String {
        let hasDuplicateName = vaults.contains { candidate in
            candidate.id != vault.id && candidate.name == vault.name
        }
        return hasDuplicateName ? "\(vault.name) — \(vault.path ?? vault.id.uuidString)" : vault.name
    }
}
