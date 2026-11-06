import Foundation
import Observation

/// Adds Databricks workspaces; the account menu signs out of them. `WorkspaceAISettingsModel.databricksConnections` lists them.
@MainActor
@Observable
final class DatabricksAccountController {
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    private let service: DatabricksOAuthService

    init(service: DatabricksOAuthService = .shared) { self.service = service }

    func signIn(workspaceURL: String) async -> UUID? {
        guard !isBusy else { return nil }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let connection = try await service.signIn(workspaceURL: workspaceURL)
            try Task.checkCancellation()
            return connection.id
        } catch is CancellationError {
            return nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
}
