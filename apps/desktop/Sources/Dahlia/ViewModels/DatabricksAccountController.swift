import Foundation
import Observation

@MainActor
@Observable
final class DatabricksAccountController {
    private(set) var connection: DatabricksConnection?
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    private let service: DatabricksOAuthService

    init(service: DatabricksOAuthService = .shared) { self.service = service }

    func load() async {
        do {
            connection = try await service.currentConnection()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signIn(workspaceURL: String) async -> String? {
        guard !isBusy else { return nil }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let connection = try await service.signIn(workspaceURL: workspaceURL)
            try Task.checkCancellation()
            await load()
            return connection.id.uuidString
        } catch is CancellationError {
            return nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func remove(_ id: UUID) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await service.remove(connectionID: id)
            await load()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
