import Foundation

/// The common catalog and schema of a Databricks provider account, shared by storage and other capabilities.
/// Saved per connection on this Mac.
struct DatabricksCatalogSchema: Equatable, Sendable, CustomStringConvertible {
    let catalog: String
    let schema: String

    /// Exactly two non-empty names separated by one dot. The names become URL path components, so separators,
    /// quoting, and whitespace are rejected.
    init?(_ value: String) {
        let parts = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ Self.isValidName(String($0)) }) else { return nil }
        catalog = String(parts[0])
        schema = String(parts[1])
    }

    var description: String { "\(catalog).\(schema)" }

    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 255
            && !name.contains { $0.isWhitespace || "./`\\".contains($0) }
            && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    static func load(connectionID: UUID, repository: MeetingRepository? = nil) async throws -> Self? {
        try await (repository ?? MeetingRepository.providerAccounts()).fetchProviderAccountSettings(id: connectionID).catalogSchema
    }

    static func save(
        _ location: Self?,
        connectionID: UUID,
        repository: MeetingRepository? = nil,
        validate: @escaping @Sendable () throws -> Void = {}
    ) async throws {
        try await (repository ?? MeetingRepository.providerAccounts()).saveDatabricksCatalogSchema(
            location,
            accountID: connectionID,
            validate: validate
        )
    }

    static func didChange(connectionID: UUID) -> Notification.Name { ProviderAccountSettings.didChange(accountID: connectionID) }
}
