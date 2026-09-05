import Foundation

enum ProjectWorkspaceError: LocalizedError, Equatable {
    case projectNotFound
    case invalidName
    case nameTooLong
    case descriptionTooLong
    case projectAlreadyExists(String)
    case typeOwnedByRoot
    case staleRevision(current: Int)
    case cycleDetected
    case hierarchyTooDeep
    case vaultBusy
    case trashLocationUnavailable
    case invalidMoveDestination
    case invalidSummaryOutputDestination
    case summaryFileAlreadyExists(String)
    case summaryFileShared(String)
    case rollbackFailed(operation: String, rollback: String)

    var errorDescription: String? {
        switch self {
        case .projectNotFound:
            L10n.projectNotFound
        case .invalidName:
            L10n.invalidProjectName
        case .nameTooLong:
            L10n.projectNameTooLong
        case .descriptionTooLong:
            L10n.projectDescriptionTooLong
        case let .projectAlreadyExists(name):
            L10n.projectAlreadyExists(name)
        case .typeOwnedByRoot:
            L10n.subprojectTypeInheritanceError
        case let .staleRevision(current):
            L10n.staleProjectRevision(current)
        case .cycleDetected:
            L10n.projectCycleError
        case .hierarchyTooDeep:
            L10n.projectHierarchyTooDeep
        case .vaultBusy:
            L10n.projectVaultBusy
        case .trashLocationUnavailable:
            L10n.summaryTrashLocationUnavailable
        case .invalidMoveDestination:
            L10n.invalidProjectMoveDestination
        case .invalidSummaryOutputDestination:
            L10n.invalidSummaryOutputDestination
        case let .summaryFileAlreadyExists(name):
            L10n.summaryFileAlreadyExists(name)
        case let .summaryFileShared(name):
            L10n.summaryFileShared(name)
        case let .rollbackFailed(operation, rollback):
            L10n.projectRollbackFailed(operation: operation, rollback: rollback)
        }
    }
}
