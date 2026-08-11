import DahliaRuntimeSupport
import Foundation
import GRDB
import Observation

@MainActor
@Observable
final class CustomerIntelligenceProjectsViewModel {
    var searchText = ""
    private(set) var projects: [CustomerIntelligenceWorkspaceData.ProjectSummary] = []
    private(set) var detail: CustomerIntelligenceWorkspaceData.ProjectDetail?
    private(set) var isLoading = false
    private(set) var isSaving = false
    var errorMessage: String?

    private let dbQueue: DatabaseQueue
    private let vaultID: UUID
    private let scope: CustomerIntelligenceScope
    private var loadGeneration = 0
    private var detailGeneration = 0
    private let notificationSenderID =
        CustomerIntelligenceWorkspaceViewModel.sectionMutationSenderPrefix + UUID().uuidString

    init(dbQueue: DatabaseQueue, vaultID: UUID, scope: CustomerIntelligenceScope) {
        self.dbQueue = dbQueue
        self.vaultID = vaultID
        self.scope = scope
    }

    var filteredProjects: [CustomerIntelligenceWorkspaceData.ProjectSummary] {
        guard let query = searchText.nilIfBlank else { return projects }
        return projects.filter {
            $0.project.path.localizedStandardContains(query)
                || $0.project.description.localizedStandardContains(query)
                || $0.organizationNames.contains { $0.localizedStandardContains(query) }
                || $0.contactNames.contains { $0.localizedStandardContains(query) }
        }
    }

    func load(selectedID: UUID? = nil) async {
        loadGeneration += 1
        detailGeneration += 1
        let generation = loadGeneration
        let requestedDetailGeneration = detailGeneration
        isLoading = true
        detail = nil
        defer {
            if generation == loadGeneration {
                isLoading = false
            }
        }
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                let repository = MeetingRepository(dbQueue: self.dbQueue)
                let projects = try repository.fetchCustomerIntelligenceProjects(
                    vaultId: self.vaultID,
                    scope: self.scope
                )
                let detail = try selectedID.flatMap {
                    try repository.fetchCustomerIntelligenceProjectDetail(id: $0, vaultId: self.vaultID)
                }
                return (projects, detail)
            }.value
            guard generation == loadGeneration else { return }
            projects = result.0
            if requestedDetailGeneration == detailGeneration {
                detail = result.1
            }
            errorMessage = nil
        } catch {
            guard generation == loadGeneration else { return }
            setError(error)
        }
    }

    func select(_ id: UUID?) async {
        detailGeneration += 1
        let generation = detailGeneration
        detail = nil
        guard let id else {
            return
        }
        do {
            let loadedDetail = try await Task.detached(priority: .userInitiated) {
                try MeetingRepository(dbQueue: self.dbQueue)
                    .fetchCustomerIntelligenceProjectDetail(id: id, vaultId: self.vaultID)
            }.value
            guard generation == detailGeneration else { return }
            detail = loadedDetail
            errorMessage = nil
        } catch {
            guard generation == detailGeneration else { return }
            setError(error)
        }
    }

    func didMutate(selecting id: UUID?) async {
        DahliaWorkspaceChangeNotification.post(vaultID: vaultID, senderID: notificationSenderID)
        await load(selectedID: id)
    }

    func setSaving(_ value: Bool) {
        isSaving = value
    }

    func report(_ error: Error) {
        setError(error)
    }

    private func setError(_ error: Error) {
        if let databaseError = error as? DatabaseError,
           databaseError.resultCode == .SQLITE_BUSY || databaseError.resultCode == .SQLITE_LOCKED {
            errorMessage = L10n.organizationWorkspaceBusy
        } else {
            errorMessage = error.localizedDescription
        }
    }
}
