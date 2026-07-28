import DahliaRuntimeSupport
import Foundation
import GRDB
import Observation

@MainActor
@Observable
final class CustomerIntelligenceInsightsViewModel {
    var searchText = ""
    var isAccepted: Bool? = false
    private(set) var insights: [CustomerIntelligenceWorkspaceData.InsightSummary] = []
    private(set) var detail: CustomerIntelligenceWorkspaceData.InsightDetail?
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

    var filteredInsights: [CustomerIntelligenceWorkspaceData.InsightSummary] {
        insights.filter {
            (isAccepted == nil || $0.insight.isAccepted == isAccepted)
                && (searchText.nilIfBlank == nil
                    || $0.insight.content.localizedStandardContains(searchText))
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
                let insights = try repository.fetchCustomerIntelligenceInsights(
                    vaultId: self.vaultID,
                    scope: self.scope
                )
                let detail = try selectedID.flatMap {
                    try repository.fetchCustomerIntelligenceInsightDetail(id: $0, vaultId: self.vaultID)
                }
                return (insights, detail)
            }.value
            guard generation == loadGeneration else { return }
            insights = result.0
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
                    .fetchCustomerIntelligenceInsightDetail(id: id, vaultId: self.vaultID)
            }.value
            guard generation == detailGeneration else { return }
            detail = loadedDetail
        } catch {
            guard generation == detailGeneration else { return }
            setError(error)
        }
    }

    func setAccepted(_ isAccepted: Bool) async {
        guard let insight = detail?.summary.insight else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await Task.detached(priority: .userInitiated) {
                try MeetingRepository(dbQueue: self.dbQueue).setInsightAccepted(
                    id: insight.id,
                    vaultId: self.vaultID,
                    expectedRevision: insight.revision,
                    isAccepted: isAccepted
                )
            }.value
            DahliaWorkspaceChangeNotification.post(vaultID: vaultID, senderID: notificationSenderID)
            await load(selectedID: insight.id)
        } catch {
            setError(error)
        }
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
