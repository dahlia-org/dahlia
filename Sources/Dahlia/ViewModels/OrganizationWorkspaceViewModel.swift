import DahliaRuntimeSupport
import Foundation
import GRDB
import Observation

@MainActor
@Observable
// swiftlint:disable:next type_body_length
final class OrganizationWorkspaceViewModel {
    struct PendingOrganizationDeletion: Identifiable {
        let organization: OrganizationRecord
        let impact: OrganizationDeletionImpact
        var id: UUID { organization.id }
    }

    struct PendingOrganizationMerge: Identifiable {
        let preview: OrganizationMergePreview
        var id: UUID { preview.source.id }
    }

    private(set) var roots: [OrganizationWorkspaceNode] = []
    private(set) var contacts: [ContactRecord] = []
    private(set) var organizationCandidates: [OrganizationRecord] = []
    private(set) var loadedNodes: [UUID: OrganizationWorkspaceNode] = [:]
    private(set) var loadedChildCounts: [UUID: Int] = [:]
    private(set) var expandedNodeIDs: Set<UUID> = []
    private(set) var selectedRootID: UUID?
    var selectedNodeID: UUID?
    private(set) var selectedDetail: OrganizationWorkspaceDetail?
    private(set) var allTopics: [ConversationTopicOverview] = []
    var selectedTopicID: UUID?
    private(set) var highlightedOrganizationIDs: Set<UUID> = []
    private(set) var selectedTopicEvidence: [ConversationTopicMeetingEvidence] = []
    private(set) var canvasLayout = OrganizationCanvasLayoutResult(positions: [:], size: .zero)
    private(set) var loadingChildNodeIDs: Set<UUID> = []
    var searchText = ""
    var isLoading = false
    private(set) var isPreparingDeletion = false
    private(set) var isMutating = false
    var errorMessage: String?
    var pendingDeletion: PendingOrganizationDeletion?
    var pendingMerge: PendingOrganizationMerge?

    private let dbQueue: DatabaseQueue?
    private var vaultID: UUID?
    @ObservationIgnored private nonisolated(unsafe) var notificationObserver: NSObjectProtocol?
    private var loadGeneration = 0
    private var detailGeneration = 0
    private var topicGeneration = 0
    private var searchGeneration = 0
    private var layoutGeneration = 0
    private var needsReload = false
    private let notificationSenderID = UUID().uuidString

    init(dbQueue: DatabaseQueue?, vaultID: UUID?) {
        self.dbQueue = dbQueue
        self.vaultID = vaultID
        observeWorkspaceChanges()
    }

    deinit {
        if let notificationObserver {
            DistributedNotificationCenter.default().removeObserver(notificationObserver)
        }
    }

    var visibleNodes: [OrganizationWorkspaceNode] {
        guard let rootID = selectedRootID, loadedNodes[rootID] != nil else { return [] }
        let childrenByParent = Dictionary(
            grouping: loadedNodes.values.compactMap { node -> OrganizationWorkspaceNode? in
                node.organization.parentOrganizationId == nil ? nil : node
            },
            by: { $0.organization.parentOrganizationId! }
        ).mapValues {
            $0.sorted {
                $0.organization.name.localizedCaseInsensitiveCompare($1.organization.name) == .orderedAscending
            }
        }
        var result: [OrganizationWorkspaceNode] = []
        func append(_ id: UUID) {
            guard let node = loadedNodes[id] else { return }
            result.append(node)
            guard expandedNodeIDs.contains(id) else { return }
            childrenByParent[id, default: []].forEach { append($0.id) }
        }
        append(rootID)
        return result
    }

    var filteredRoots: [OrganizationWorkspaceNode] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return roots }
        return roots.filter {
            $0.organization.name.localizedCaseInsensitiveContains(query)
                || $0.organization.description.localizedCaseInsensitiveContains(query)
        }
    }

    func load(selectingRootID requestedRootID: UUID? = nil) async {
        let previouslySelectedNodeID = selectedNodeID
        while true {
            let iterationIsCurrent = await loadWorkspaceIteration(
                preferredRootID: requestedRootID,
                previouslySelectedNodeID: previouslySelectedNodeID
            )
            if iterationIsCurrent {
                isLoading = false
            }
            guard needsReload else { return }
            needsReload = false
        }
    }

    private func loadWorkspaceIteration(
        preferredRootID: UUID?,
        previouslySelectedNodeID: UUID?
    ) async -> Bool {
        guard dbQueue != nil, let vaultID else { return true }
        loadGeneration += 1
        detailGeneration += 1
        topicGeneration += 1
        searchGeneration += 1
        let generation = loadGeneration
        isLoading = true
        do {
            let result = try await performRead { repository in
                try (
                    roots: repository.fetchRootOrganizationWorkspaceNodes(vaultId: vaultID),
                    contacts: repository.fetchContacts(vaultId: vaultID)
                )
            }
            guard generation == loadGeneration else { return false }
            await applyLoadedWorkspace(
                result,
                preferredRootID: preferredRootID,
                previouslySelectedNodeID: previouslySelectedNodeID,
                generation: generation
            )
        } catch {
            guard generation == loadGeneration else { return false }
            setError(error)
        }
        return generation == loadGeneration
    }

    private func applyLoadedWorkspace(
        _ result: (roots: [OrganizationWorkspaceNode], contacts: [ContactRecord]),
        preferredRootID: UUID?,
        previouslySelectedNodeID: UUID?,
        generation: Int
    ) async {
        roots = result.roots
        contacts = result.contacts
        errorMessage = nil
        if let rootID = preferredRootID, roots.contains(where: { $0.id == rootID }) {
            await selectRoot(rootID, expectedLoadGeneration: generation)
        } else if let rootID = selectedRootID, roots.contains(where: { $0.id == rootID }) {
            await selectRoot(rootID, expectedLoadGeneration: generation)
            guard generation == loadGeneration else { return }
            if let previouslySelectedNodeID, previouslySelectedNodeID != rootID {
                await revealOrganization(previouslySelectedNodeID)
            }
        } else if let first = roots.first {
            await selectRoot(first.id, expectedLoadGeneration: generation)
        } else {
            selectedRootID = nil
            selectedNodeID = nil
            selectedDetail = nil
            loadedNodes = [:]
            canvasLayout = OrganizationCanvasLayoutResult(positions: [:], size: .zero)
        }
    }

    func changeVault(to id: UUID?) async {
        guard vaultID != id else { return }
        if let notificationObserver {
            DistributedNotificationCenter.default().removeObserver(notificationObserver)
            self.notificationObserver = nil
        }
        vaultID = id
        clearWorkspaceProjection()
        observeWorkspaceChanges()
        await load()
    }

    func selectRoot(_ id: UUID) async {
        await selectRoot(id, expectedLoadGeneration: nil)
    }

    private func selectRoot(_ id: UUID, expectedLoadGeneration: Int?) async {
        guard expectedLoadGeneration == nil || expectedLoadGeneration == loadGeneration else { return }
        guard let root = roots.first(where: { $0.id == id }) else { return }
        selectedRootID = id
        selectedNodeID = id
        selectedDetail = nil
        selectedTopicID = nil
        allTopics = []
        highlightedOrganizationIDs = []
        selectedTopicEvidence = []
        loadedNodes = [id: root]
        organizationCandidates = []
        loadedChildCounts = [:]
        expandedNodeIDs = []
        await loadOrganizationCandidates(for: id)
        guard expectedLoadGeneration == nil || expectedLoadGeneration == loadGeneration else { return }
        await loadTopics(for: id)
        guard expectedLoadGeneration == nil || expectedLoadGeneration == loadGeneration else { return }
        await expand(id, expectedLoadGeneration: expectedLoadGeneration)
        guard expectedLoadGeneration == nil || expectedLoadGeneration == loadGeneration else { return }
        await loadDetail()
    }

    func toggleExpansion(_ id: UUID) async {
        if expandedNodeIDs.contains(id) {
            expandedNodeIDs.remove(id)
            await updateLayout()
        } else {
            await expand(id)
        }
    }

    func loadMoreChildren(of id: UUID) async {
        await loadChildren(of: id, offset: loadedChildCounts[id] ?? 0)
        await updateLayout()
    }

    func selectNode(_ id: UUID) async {
        selectedNodeID = id
        selectedDetail = nil
        await loadDetail()
    }

    func selectTopic(_ id: UUID?) async {
        topicGeneration += 1
        let generation = topicGeneration
        selectedTopicID = id
        highlightedOrganizationIDs = []
        selectedTopicEvidence = []
        guard let id, dbQueue != nil, let vaultID else { return }
        guard allTopics.contains(where: { $0.id == id }) else {
            selectedTopicID = nil
            return
        }
        do {
            let result = try await performRead { repository in
                let relatedPaths = try repository.fetchConversationTopicRelatedOrganizationPaths(
                    id: id,
                    vaultId: vaultID
                )
                let evidence = try repository.fetchConversationTopicMeetingEvidence(id: id, vaultId: vaultID)
                return (relatedPaths.paths, evidence)
            }
            guard generation == topicGeneration, selectedTopicID == id else { return }
            selectedTopicEvidence = result.1
            let visiblePaths = result.0.filter { $0.first?.id == selectedRootID }
            highlightedOrganizationIDs = Set(visiblePaths.compactMap(\.last?.id))
            for path in visiblePaths {
                for node in path {
                    loadedNodes[node.id] = node
                }
                expandedNodeIDs.formUnion(path.dropLast().map(\.id))
            }
            await updateLayout()
        } catch {
            guard generation == topicGeneration, selectedTopicID == id else { return }
            setError(error)
        }
    }

    private func loadTopics(for rootID: UUID) async {
        guard dbQueue != nil, let vaultID else { return }
        topicGeneration += 1
        let generation = topicGeneration
        do {
            let topics = try await performRead {
                try $0.fetchConversationTopics(
                    vaultId: vaultID,
                    scope: .organization(rootID)
                )
            }
            guard generation == topicGeneration, selectedRootID == rootID else { return }
            allTopics = topics
        } catch {
            guard generation == topicGeneration, selectedRootID == rootID else { return }
            setError(error)
        }
    }

    private func loadOrganizationCandidates(for rootID: UUID) async {
        guard dbQueue != nil, let vaultID else { return }
        let generation = loadGeneration
        do {
            let organizations = try await performRead {
                try $0.fetchOrganizationWorkspaceSubtree(
                    rootOrganizationId: rootID,
                    vaultId: vaultID
                )
            }
            guard generation == loadGeneration, selectedRootID == rootID else { return }
            organizationCandidates = organizations
        } catch {
            guard generation == loadGeneration, selectedRootID == rootID else { return }
            setError(error)
        }
    }

    func searchAndRevealFirstMatch() async {
        guard dbQueue != nil, let vaultID, let selectedRootID else { return }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        searchGeneration += 1
        let generation = searchGeneration
        do {
            let organizations = try await performRead {
                try $0.searchOrganizationWorkspaceNodes(
                    vaultId: vaultID,
                    rootOrganizationId: selectedRootID,
                    query: query
                )
            }
            guard generation == searchGeneration, searchText.nilIfBlank == query else { return }
            guard let match = organizations.first else { return }
            let path = try await performRead {
                try $0.fetchOrganizationWorkspacePath(id: match.id, vaultId: vaultID)
            }
            guard generation == searchGeneration, searchText.nilIfBlank == query else { return }
            guard path.first?.id == selectedRootID else { return }
            loadedNodes = Dictionary(uniqueKeysWithValues: path.map { ($0.id, $0) })
            expandedNodeIDs = Set(path.dropLast().map(\.id))
            selectedNodeID = match.id
            await updateLayout()
            await loadDetail()
        } catch {
            guard generation == searchGeneration, searchText.nilIfBlank == query else { return }
            setError(error)
        }
    }

    func updateSelectedOrganization(name: String, parentID: UUID?, description: String) async -> Bool {
        guard let id = selectedNodeID, id != parentID, let node = loadedNodes[id], let vaultID else {
            return false
        }
        return await mutate(vaultID: vaultID) {
            try $0.updateOrganization(
                id: id,
                vaultId: vaultID,
                name: name,
                parentOrganizationId: parentID,
                description: description,
                expectedRevision: node.organization.revision
            )
        }
    }

    func createRootOrganization(name: String, description: String = "") async {
        guard let vaultID else { return }
        await mutate(vaultID: vaultID, operation: {
            try $0.createOrganization(
                vaultId: vaultID,
                parentOrganizationId: nil,
                nodeKind: .organization,
                name: name,
                description: description
            )
        }, onSuccess: { organization in
            selectedRootID = organization.id
        })
    }

    func addDomain(_ rawDomainName: String, to target: OrganizationRecord) async -> Bool {
        guard let domainName = CustomerIdentityNormalizer.domainName(rawDomainName) else {
            setError(CustomerIntelligenceError.invalidDomain)
            return false
        }
        guard target.isRootOrganization,
              vaultID == target.vaultId,
              dbQueue != nil,
              let vaultID
        else {
            setError(CustomerIntelligenceError.revisionConflict)
            return false
        }
        do {
            let plan = try await performRead {
                try $0.organizationDomainAssignmentPlan(
                    targetOrganizationId: target.id,
                    vaultId: vaultID,
                    domainName: domainName,
                    expectedTargetRevision: target.revision
                )
            }
            guard self.vaultID == vaultID else { return false }
            switch plan {
            case .unassigned:
                return await mutate(vaultID: vaultID) {
                    try $0.addOrganizationDomain(
                        organizationId: target.id,
                        vaultId: vaultID,
                        domainName: domainName,
                        expectedOrganizationRevision: target.revision
                    )
                }
            case .alreadyAssigned:
                return true
            case let .merge(preview):
                pendingMerge = PendingOrganizationMerge(preview: preview)
                return true
            }
        } catch {
            setError(error)
            return false
        }
    }

    func confirmMerge(_ pending: PendingOrganizationMerge) async {
        pendingMerge = nil
        let preview = pending.preview
        guard let vaultID else { return }
        await mutate(vaultID: vaultID) {
            try $0.mergeOrganization(
                sourceOrganizationId: preview.source.id,
                targetOrganizationId: preview.target.id,
                vaultId: vaultID,
                expectedSourceDomainName: preview.domainName,
                expectedSourceRevision: preview.source.revision,
                expectedTargetRevision: preview.target.revision,
                expectedImpact: preview.impact
            )
        }
    }

    func addMember(contactID: UUID, role: String?) async -> Bool {
        guard let organizationID = selectedNodeID, let node = loadedNodes[organizationID],
              let vaultID else { return false }
        return await mutate(vaultID: vaultID) {
            try $0.addOrganizationMembership(
                organizationId: organizationID,
                contactId: contactID,
                roleLabel: role,
                expectedOrganizationRevision: node.organization.revision
            )
        }
    }

    func prepareOrganizationDeletion() async {
        guard let id = selectedNodeID, loadedNodes[id] != nil,
              dbQueue != nil, let vaultID, !isPreparingDeletion else { return }
        isPreparingDeletion = true
        let result: Result<(organization: OrganizationRecord, impact: OrganizationDeletionImpact), Error>
        do {
            let preview = try await performRead { repository in
                try repository.organizationDeletionPreview(id: id, vaultId: vaultID)
            }
            result = .success(preview)
        } catch {
            result = .failure(error)
        }
        isPreparingDeletion = false
        if needsReload {
            await reloadIfNeeded()
            guard selectedNodeID == id else { return }
            await prepareOrganizationDeletion()
            return
        }
        switch result {
        case let .success(preview):
            guard self.vaultID == vaultID, selectedNodeID == id else { return }
            pendingDeletion = PendingOrganizationDeletion(
                organization: preview.organization,
                impact: preview.impact
            )
        case let .failure(error):
            setError(error)
        }
    }

    private func confirmOrganizationDeletion(_ pending: PendingOrganizationDeletion) async {
        guard let vaultID else { return }
        await mutate(vaultID: vaultID) {
            try $0.deleteOrganization(
                id: pending.id,
                vaultId: vaultID,
                expectedRevision: pending.organization.revision,
                expectedImpact: pending.impact
            )
        }
    }

    func confirmDeletion(_ pending: PendingOrganizationDeletion) async {
        pendingDeletion = nil
        await confirmOrganizationDeletion(pending)
    }

    private func expand(_ id: UUID, expectedLoadGeneration: Int? = nil) async {
        if loadedChildCounts[id] == nil {
            await loadChildren(of: id, offset: 0)
        }
        guard expectedLoadGeneration == nil || expectedLoadGeneration == loadGeneration else { return }
        expandedNodeIDs.insert(id)
        await updateLayout()
    }

    private func loadChildren(of id: UUID, offset: Int) async {
        guard dbQueue != nil, let vaultID, loadingChildNodeIDs.insert(id).inserted else { return }
        defer { loadingChildNodeIDs.remove(id) }
        let rootID = selectedRootID
        let generation = loadGeneration
        do {
            let children = try await performRead {
                try $0.fetchOrganizationWorkspaceChildren(
                    parentId: id,
                    vaultId: vaultID,
                    limit: 50,
                    offset: offset
                )
            }
            guard generation == loadGeneration, self.vaultID == vaultID,
                  selectedRootID == rootID, loadedNodes[id] != nil
            else { return }
            for child in children {
                loadedNodes[child.id] = child
            }
            loadedChildCounts[id] = offset + children.count
        } catch {
            guard generation == loadGeneration, self.vaultID == vaultID,
                  selectedRootID == rootID
            else { return }
            setError(error)
        }
    }

    private func loadDetail() async {
        guard dbQueue != nil, let vaultID, let selectedNodeID else {
            selectedDetail = nil
            return
        }
        detailGeneration += 1
        let generation = detailGeneration
        do {
            let detail = try await performRead {
                try $0.fetchOrganizationWorkspaceDetail(
                    organizationId: selectedNodeID,
                    vaultId: vaultID
                )
            }
            guard generation == detailGeneration, self.selectedNodeID == selectedNodeID else { return }
            selectedDetail = detail
        } catch {
            guard generation == detailGeneration, self.selectedNodeID == selectedNodeID else { return }
            setError(error)
        }
    }

    private func updateLayout() async {
        layoutGeneration += 1
        let generation = layoutGeneration
        let visible = visibleNodes
        let depthByID = visible.reduce(into: [UUID: Int]()) { partial, node in
            partial[node.id] = node.organization.parentOrganizationId.flatMap { partial[$0] }.map { $0 + 1 } ?? 0
        }
        let inputs = visible.map {
            OrganizationCanvasLayoutInputNode(
                id: $0.id,
                depth: depthByID[$0.id] ?? 0
            )
        }
        let layout = await Task.detached {
            OrganizationCanvasLayout.calculate(nodes: inputs)
        }.value
        guard generation == layoutGeneration else { return }
        canvasLayout = layout
    }

    func revealOrganization(_ id: UUID) async {
        guard dbQueue != nil, let vaultID else { return }
        let generation = loadGeneration
        do {
            let path = try await performRead {
                try $0.fetchOrganizationWorkspacePath(id: id, vaultId: vaultID)
            }
            guard generation == loadGeneration,
                  path.first?.id == selectedRootID,
                  let selected = path.last else { return }
            for node in path {
                loadedNodes[node.id] = node
            }
            expandedNodeIDs.formUnion(path.dropLast().map(\.id))
            selectedNodeID = selected.id
            await updateLayout()
            guard generation == loadGeneration, selectedNodeID == selected.id else { return }
            await loadDetail()
        } catch {
            guard generation == loadGeneration, self.vaultID == vaultID else { return }
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

    private func performRead<Value: Sendable>(
        _ operation: @escaping @Sendable (MeetingRepository) throws -> Value
    ) async throws -> Value {
        guard let dbQueue else { throw CustomerIntelligenceError.vaultNotFound }
        return try await Task.detached(priority: .userInitiated) {
            try operation(MeetingRepository(dbQueue: dbQueue))
        }.value
    }

    private func performWrite<Value: Sendable>(
        _ operation: @escaping @Sendable (MeetingRepository) throws -> Value
    ) async throws -> Value {
        guard let dbQueue else { throw CustomerIntelligenceError.vaultNotFound }
        return try await Task.detached(priority: .userInitiated) {
            try operation(MeetingRepository(dbQueue: dbQueue))
        }.value
    }

    @discardableResult
    private func mutate<Value: Sendable>(
        vaultID: UUID,
        operation: @escaping @Sendable (MeetingRepository) throws -> Value,
        onSuccess: (Value) -> Void = { _ in }
    ) async -> Bool {
        guard !isMutating, self.vaultID == vaultID else { return false }
        isMutating = true
        defer { isMutating = false }
        do {
            let value = try await performWrite(operation)
            guard self.vaultID == vaultID else { return false }
            onSuccess(value)
            DahliaWorkspaceChangeNotification.post(vaultID: vaultID, senderID: notificationSenderID)
            await load()
            return true
        } catch {
            guard self.vaultID == vaultID else { return false }
            setError(error)
            return false
        }
    }

    private func clearWorkspaceProjection() {
        loadGeneration += 1
        detailGeneration += 1
        topicGeneration += 1
        searchGeneration += 1
        layoutGeneration += 1
        roots = []
        contacts = []
        organizationCandidates = []
        loadedNodes = [:]
        loadedChildCounts = [:]
        expandedNodeIDs = []
        selectedRootID = nil
        selectedNodeID = nil
        selectedDetail = nil
        allTopics = []
        selectedTopicID = nil
        highlightedOrganizationIDs = []
        selectedTopicEvidence = []
        loadingChildNodeIDs = []
        canvasLayout = OrganizationCanvasLayoutResult(positions: [:], size: .zero)
        pendingDeletion = nil
        pendingMerge = nil
        needsReload = false
        errorMessage = nil
        isLoading = false
        isPreparingDeletion = false
    }

    private func reloadIfNeeded() async {
        guard needsReload, !isLoading, !isPreparingDeletion else { return }
        needsReload = false
        await load()
    }

    @discardableResult
    func handleWorkspaceChange() async -> Bool {
        loadGeneration += 1
        detailGeneration += 1
        topicGeneration += 1
        searchGeneration += 1
        layoutGeneration += 1
        if isLoading || isPreparingDeletion {
            needsReload = true
            return true
        }
        await load()
        return false
    }

    private func observeWorkspaceChanges() {
        guard let vaultID else { return }
        notificationObserver = DistributedNotificationCenter.default().addObserver(
            forName: DahliaWorkspaceChangeNotification.name(vaultID: vaultID),
            object: nil,
            queue: .main
        ) { [weak self, notificationSenderID] notification in
            guard notification.object as? String != notificationSenderID else { return }
            Task { @MainActor [weak self] in
                await self?.handleWorkspaceChange()
            }
        }
    }
}
