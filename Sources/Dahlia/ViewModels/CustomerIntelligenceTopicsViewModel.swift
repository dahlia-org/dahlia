import DahliaRuntimeSupport
import Foundation
import GRDB
import Observation

@MainActor
@Observable
final class CustomerIntelligenceTopicsViewModel {
    struct PendingDeletion: Identifiable {
        let topic: ConversationTopicRecord
        let impact: TopicDeletionImpact

        var id: UUID { topic.id }
    }

    var searchText = ""
    private(set) var topics: [ConversationTopicOverview] = []
    private(set) var detail: CustomerIntelligenceWorkspaceData.TopicDetail?
    private(set) var isLoading = false
    private(set) var isSaving = false
    var errorMessage: String?
    var pendingDeletion: PendingDeletion?

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

    var filteredTopics: [ConversationTopicOverview] {
        guard let query = searchText.nilIfBlank else { return topics }
        return topics.filter {
            $0.topic.title.localizedStandardContains(query)
                || $0.topic.currentState.localizedStandardContains(query)
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
                let topics = try repository.fetchConversationTopics(vaultId: self.vaultID, scope: self.scope)
                let detail = try selectedID.flatMap {
                    try repository.fetchCustomerIntelligenceTopicDetail(id: $0, vaultId: self.vaultID)
                }
                return (topics, detail)
            }.value
            guard generation == loadGeneration else { return }
            topics = result.0
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
                    .fetchCustomerIntelligenceTopicDetail(id: id, vaultId: self.vaultID)
            }.value
            guard generation == detailGeneration else { return }
            detail = loadedDetail
            errorMessage = nil
        } catch {
            guard generation == detailGeneration else { return }
            setError(error)
        }
    }

    func create(title: String, currentState: String, organizationID: UUID) async -> UUID? {
        guard title.nilIfBlank != nil, currentState.nilIfBlank != nil else { return nil }
        isSaving = true
        defer { isSaving = false }
        do {
            let topic = try await Task.detached(priority: .userInitiated) {
                try MeetingRepository(dbQueue: self.dbQueue).createConversationTopic(
                    vaultId: self.vaultID,
                    title: title,
                    currentState: currentState,
                    references: [.init(resourceType: .organization, resourceID: organizationID)]
                )
            }.value
            DahliaWorkspaceChangeNotification.post(vaultID: vaultID, senderID: notificationSenderID)
            await load(selectedID: topic.id)
            return topic.id
        } catch {
            setError(error)
            return nil
        }
    }

    func save(topic: ConversationTopicRecord, title: String, currentState: String) async -> Bool {
        isSaving = true
        defer { isSaving = false }
        do {
            let updated = try await Task.detached(priority: .userInitiated) {
                try MeetingRepository(dbQueue: self.dbQueue).updateConversationTopic(
                    id: topic.id,
                    vaultId: self.vaultID,
                    expectedRevision: topic.revision,
                    title: title,
                    currentState: currentState
                )
            }.value
            DahliaWorkspaceChangeNotification.post(vaultID: vaultID, senderID: notificationSenderID)
            await load(selectedID: updated.id)
            return true
        } catch {
            setError(error)
            return false
        }
    }

    func prepareDeletion(_ topic: ConversationTopicRecord) async {
        do {
            let impact = try await Task.detached(priority: .userInitiated) {
                try MeetingRepository(dbQueue: self.dbQueue)
                    .topicDeletionImpact(id: topic.id, vaultId: self.vaultID)
            }.value
            pendingDeletion = PendingDeletion(topic: topic, impact: impact)
        } catch {
            setError(error)
        }
    }

    func confirmDeletion(_ pending: PendingDeletion) async -> Bool {
        isSaving = true
        defer { isSaving = false }
        do {
            try await Task.detached(priority: .userInitiated) {
                try MeetingRepository(dbQueue: self.dbQueue).deleteConversationTopic(
                    id: pending.topic.id,
                    vaultId: self.vaultID,
                    expectedRevision: pending.topic.revision,
                    expectedImpact: pending.impact
                )
            }.value
            pendingDeletion = nil
            DahliaWorkspaceChangeNotification.post(vaultID: vaultID, senderID: notificationSenderID)
            await load()
            return true
        } catch {
            setError(error)
            return false
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
