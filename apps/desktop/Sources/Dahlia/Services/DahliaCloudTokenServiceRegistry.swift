import Foundation

actor DahliaCloudTokenServiceRegistry {
    static let shared = DahliaCloudTokenServiceRegistry()

    private var services: [UUID: DahliaCloudService] = [:]

    func register(_ service: DahliaCloudService, connectionID: UUID) {
        services[connectionID] = service
    }

    func remove(connectionID: UUID) {
        services.removeValue(forKey: connectionID)
    }

    func validAccessToken(connectionID: UUID, forceRefresh: Bool = false) async throws -> String {
        guard let service = services[connectionID] else { throw DahliaCloudError.noCredential }
        return try await service.validAccessToken(minimumValidity: 6 * 60, forceRefresh: forceRefresh)
    }
}
