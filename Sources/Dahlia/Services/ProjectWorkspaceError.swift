import Foundation

enum ProjectWorkspaceError: LocalizedError, Equatable {
    case projectNotFound
    case parentFolderMissing
    case invalidName
    case nameTooLong
    case projectAlreadyExists(String)
    case folderAlreadyExists(String)
    case folderMissing
    case trashLocationUnavailable
    case invalidMoveDestination
    case summaryFileAlreadyExists(String)
    case summaryFileShared(String)
    case rollbackFailed(operation: String, rollback: String)

    var errorDescription: String? {
        switch self {
        case .projectNotFound:
            L10n.projectNotFound
        case .parentFolderMissing:
            L10n.projectParentFolderMissing
        case .invalidName:
            L10n.invalidProjectName
        case .nameTooLong:
            L10n.projectNameTooLong
        case let .projectAlreadyExists(name):
            L10n.projectAlreadyExists(name)
        case let .folderAlreadyExists(name):
            L10n.projectFolderAlreadyExists(name)
        case .folderMissing:
            L10n.projectFolderMissingForOperation
        case .trashLocationUnavailable:
            L10n.projectTrashLocationUnavailable
        case .invalidMoveDestination:
            L10n.invalidProjectMoveDestination
        case let .summaryFileAlreadyExists(name):
            L10n.summaryFileAlreadyExists(name)
        case let .summaryFileShared(name):
            L10n.summaryFileShared(name)
        case let .rollbackFailed(operation, rollback):
            L10n.projectRollbackFailed(operation: operation, rollback: rollback)
        }
    }
}
