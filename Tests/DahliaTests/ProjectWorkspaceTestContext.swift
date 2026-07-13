import Foundation
#if canImport(Testing)
    @testable import Dahlia

    struct ProjectWorkspaceTestContext {
        let rootURL: URL
        let vaultURL: URL
        let trashURL: URL
        let database: AppDatabaseManager
        let repository: MeetingRepository
        let vault: VaultRecord
        let service: ProjectWorkspaceService
    }
#endif
