import Foundation
#if canImport(Testing)
    @testable import Dahlia

    struct ProjectWorkspaceTestContext {
        let rootURL: URL
        let workspaceURL: URL
        let trashURL: URL
        let database: AppDatabaseManager
        let repository: MeetingRepository
        let workspace: WorkspaceRecord
        let service: ProjectWorkspaceService
    }
#endif
