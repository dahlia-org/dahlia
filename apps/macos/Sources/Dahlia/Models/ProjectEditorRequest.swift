import Foundation

enum ProjectEditorRequest: Identifiable {
    case create
    case edit(ProjectOverviewItem)

    var id: String {
        switch self {
        case .create: "create"
        case let .edit(project): project.projectId.uuidString
        }
    }

    var project: ProjectOverviewItem? {
        guard case let .edit(project) = self else { return nil }
        return project
    }
}
