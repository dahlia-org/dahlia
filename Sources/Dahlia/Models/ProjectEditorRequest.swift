import Foundation

enum ProjectEditorRequest: Identifiable {
    case create
    case edit(ProjectOverviewItem, initialDescription: String?, expectedRevision: Int?)

    var id: String {
        switch self {
        case .create: "create"
        case let .edit(project, _, _): project.projectId.uuidString
        }
    }

    var project: ProjectOverviewItem? {
        guard case let .edit(project, _, _) = self else { return nil }
        return project
    }

    var initialDescription: String {
        switch self {
        case .create: ""
        case let .edit(project, description, _): description ?? project.projectDescription
        }
    }

    var expectedRevision: Int? {
        guard case let .edit(project, _, expectedRevision) = self else { return nil }
        return expectedRevision ?? project.revision
    }

    var hasInitialDescription: Bool {
        guard case let .edit(_, description, _) = self else { return false }
        return description != nil
    }
}
