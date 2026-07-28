import DahliaRuntimeSupport
import Foundation
import GRDB
import Observation

@MainActor
@Observable
final class CustomerIntelligenceInsightsViewModel {
    typealias AcceptanceUpdater = @Sendable (
        DatabaseQueue,
        UUID,
        UUID,
        Int,
        Bool
    ) async throws -> InsightRecord

    var searchText = ""
    var isAccepted: Bool? = false
    private(set) var insights: [CustomerIntelligenceWorkspaceData.InsightSummary] = []
    private(set) var detail: CustomerIntelligenceWorkspaceData.InsightDetail?
    private(set) var selectedID: UUID?
    private(set) var isLoading = false
    private(set) var isSaving = false
    var errorMessage: String?

    private let dbQueue: DatabaseQueue
    private let vaultID: UUID
    private let scope: CustomerIntelligenceScope
    private let acceptanceUpdater: AcceptanceUpdater
    private var loadGeneration = 0
    private var detailGeneration = 0
    private let notificationSenderID =
        CustomerIntelligenceWorkspaceViewModel.sectionMutationSenderPrefix + UUID().uuidString

    init(
        dbQueue: DatabaseQueue,
        vaultID: UUID,
        scope: CustomerIntelligenceScope,
        acceptanceUpdater: @escaping AcceptanceUpdater = { dbQueue, id, vaultID, revision, isAccepted in
            try await Task.detached(priority: .userInitiated) {
                try MeetingRepository(dbQueue: dbQueue).setInsightAccepted(
                    id: id,
                    vaultId: vaultID,
                    expectedRevision: revision,
                    isAccepted: isAccepted
                )
            }.value
        }
    ) {
        self.dbQueue = dbQueue
        self.vaultID = vaultID
        self.scope = scope
        self.acceptanceUpdater = acceptanceUpdater
    }

    var filteredInsights: [CustomerIntelligenceWorkspaceData.InsightSummary] {
        insights.filter {
            (isAccepted == nil || $0.insight.isAccepted == isAccepted)
                && (searchText.nilIfBlank == nil
                    || $0.insight.content.localizedStandardContains(searchText))
        }
    }

    func load(selectedID: UUID? = nil) async {
        self.selectedID = selectedID
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
        selectedID = id
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
            let updated = try await acceptanceUpdater(
                dbQueue,
                insight.id,
                vaultID,
                insight.revision,
                isAccepted
            )
            DahliaWorkspaceChangeNotification.post(vaultID: vaultID, senderID: notificationSenderID)
            if let index = insights.firstIndex(where: { $0.id == updated.id }) {
                let existing = insights[index]
                insights[index] = CustomerIntelligenceWorkspaceData.InsightSummary(
                    insight: updated,
                    referenceCount: existing.referenceCount,
                    relatedTitles: existing.relatedTitles
                )
            }
            if let currentDetail = detail, currentDetail.summary.id == updated.id {
                detail = CustomerIntelligenceWorkspaceData.InsightDetail(
                    summary: CustomerIntelligenceWorkspaceData.InsightSummary(
                        insight: updated,
                        referenceCount: currentDetail.summary.referenceCount,
                        relatedTitles: currentDetail.summary.relatedTitles
                    ),
                    references: currentDetail.references
                )
            }
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
