import Foundation

/// The app-created folder directly under My Drive, saved per Google provider account on this Mac.
struct GoogleDriveStorageLocation: Equatable, Sendable {
    static let defaultFolderName = "Dahlia"
    let folderName: String

    init?(_ value: String) {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains(where: { $0.isNewline || "/\\".contains($0) }) else { return nil }
        folderName = name
    }

    static func load(accountID: UUID, repository: MeetingRepository? = nil) async throws -> Self {
        try await (repository ?? MeetingRepository.providerAccounts()).fetchProviderAccountSettings(id: accountID).googleDriveLocation
    }

    static func save(_ location: Self, accountID: UUID, repository: MeetingRepository? = nil) async throws {
        try await (repository ?? MeetingRepository.providerAccounts()).saveGoogleDriveLocation(location, accountID: accountID)
    }

    static func didChange(accountID: UUID) -> Notification.Name { ProviderAccountSettings.didChange(accountID: accountID) }
}
