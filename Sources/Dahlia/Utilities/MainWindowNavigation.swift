import Foundation
import Observation

@MainActor
@Observable
final class MainWindowNavigation {
    static let shared = MainWindowNavigation()

    private(set) var section: MainWindowSection = .meetings
    var selectedProjectId: UUID?
    var projectSearchText = ""
    var expandedProjectIds: Set<UUID> = []

    private var projectVaultId: UUID?

    private let openMainWindow: @MainActor () -> Void

    init(openMainWindow: @escaping @MainActor () -> Void = { MainWindowOpener.shared.openMainWindow() }) {
        self.openMainWindow = openMainWindow
    }

    func showMeetings() {
        section = .meetings
    }

    func showProjects() {
        section = .projects
    }

    func openProjects() {
        showProjects()
        openMainWindow()
    }

    func openMeetings() {
        showMeetings()
        openMainWindow()
    }

    func reconcileProjectCatalog(
        vaultId: UUID?,
        projects: [ProjectOverviewItem]
    ) {
        if projectVaultId != vaultId {
            projectVaultId = vaultId
            selectedProjectId = nil
            projectSearchText = ""
            expandedProjectIds.removeAll()
        }
        selectedProjectId = ProjectManagementSelection.reconciled(
            selectedProjectId: selectedProjectId,
            projects: projects
        )
    }
}
