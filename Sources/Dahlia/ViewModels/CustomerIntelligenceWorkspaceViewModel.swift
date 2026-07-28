import DahliaRuntimeSupport
import Foundation
import GRDB
import Observation

@MainActor
@Observable
final class CustomerIntelligenceWorkspaceViewModel {
    private struct NavigationLocation: Equatable {
        let section: CustomerIntelligenceSection
        let scope: CustomerIntelligenceScope
        let selection: CustomerIntelligenceSelection
    }

    nonisolated static let sectionMutationSenderPrefix = "customer-intelligence-section:"

    var section: CustomerIntelligenceSection
    var scope: CustomerIntelligenceScope
    var selection = CustomerIntelligenceSelection()
    private(set) var roots: [OrganizationWorkspaceNode] = []
    private(set) var overview = CustomerIntelligenceWorkspaceData.Overview.empty
    private(set) var reloadToken = 0
    private(set) var isLoading = false
    private var isNavigatingHistory = false
    var errorMessage: String?

    private var dbQueue: DatabaseQueue?
    private var vaultID: UUID?
    private var loadGeneration = 0
    private var backHistory: [NavigationLocation] = []
    private var forwardHistory: [NavigationLocation] = []
    private let notificationSenderID = UUID().uuidString
    @ObservationIgnored private nonisolated(unsafe) var notificationObserver: NSObjectProtocol?

    init(dbQueue: DatabaseQueue?, vaultID: UUID?) {
        let settings = AppSettings.shared
        section = CustomerIntelligenceSection(rawValue: settings.customerIntelligenceSectionRawValue) ?? .overview
        if let id = UUID(uuidString: settings.customerIntelligenceScopeRawValue) {
            scope = .organization(id)
        } else {
            scope = .all
        }
        self.dbQueue = dbQueue
        self.vaultID = vaultID
        observeWorkspaceChanges()
    }

    deinit {
        if let notificationObserver {
            DistributedNotificationCenter.default().removeObserver(notificationObserver)
        }
    }

    var counts: CustomerIntelligenceWorkspaceData.Counts { overview.counts }
    var canGoBack: Bool { !backHistory.isEmpty && !isNavigatingHistory }
    var canGoForward: Bool { !forwardHistory.isEmpty && !isNavigatingHistory }

    var selectedRoot: OrganizationWorkspaceNode? {
        guard let id = scope.organizationID else { return nil }
        return roots.first { $0.id == id }
    }

    func load() async {
        guard let dbQueue, let vaultID else {
            roots = []
            overview = .empty
            return
        }
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        defer {
            if generation == loadGeneration {
                isLoading = false
            }
        }

        do {
            let loadedRoots = try await Task.detached(priority: .userInitiated) {
                try MeetingRepository(dbQueue: dbQueue)
                    .fetchRootOrganizationWorkspaceNodes(vaultId: vaultID)
            }.value
            guard generation == loadGeneration else { return }
            roots = loadedRoots
            reconcileScope()
            errorMessage = nil
        } catch {
            guard generation == loadGeneration else { return }
            roots = []
            setError(error)
            return
        }

        do {
            let currentScope = scope
            let loadedOverview = try await Task.detached(priority: .userInitiated) {
                try MeetingRepository(dbQueue: dbQueue).fetchCustomerIntelligenceOverview(
                    vaultId: vaultID,
                    scope: currentScope
                )
            }.value
            guard generation == loadGeneration, scope == currentScope else { return }
            overview = loadedOverview
        } catch {
            guard generation == loadGeneration else { return }
            overview = .empty
            setError(error)
        }
    }

    func changeVault(to vaultID: UUID?, dbQueue: DatabaseQueue?) async {
        guard self.vaultID != vaultID || self.dbQueue !== dbQueue else { return }
        if let notificationObserver {
            DistributedNotificationCenter.default().removeObserver(notificationObserver)
            self.notificationObserver = nil
        }
        self.vaultID = vaultID
        self.dbQueue = dbQueue
        scope = .all
        selection = CustomerIntelligenceSelection()
        roots = []
        overview = .empty
        backHistory = []
        forwardHistory = []
        reloadToken += 1
        persistNavigation()
        observeWorkspaceChanges()
        await load()
    }

    func selectSection(_ section: CustomerIntelligenceSection) {
        let previousLocation = currentLocation
        self.section = section
        recordNavigation(from: previousLocation)
        persistNavigation()
    }

    func selectScope(_ scope: CustomerIntelligenceScope) async {
        guard self.scope != scope else { return }
        let previousLocation = currentLocation
        self.scope = scope
        selection = CustomerIntelligenceSelection(organizationID: scope.organizationID)
        overview = .empty
        reloadToken += 1
        persistNavigation()
        await load()
        recordNavigation(from: previousLocation)
    }

    func openOrganization(_ id: UUID) async {
        let previousLocation = currentLocation
        if let dbQueue, let vaultID,
           let rootID = try? await Task.detached(priority: .userInitiated, operation: {
               try MeetingRepository(dbQueue: dbQueue)
                   .fetchOrganizationWorkspacePath(id: id, vaultId: vaultID)
                   .first?.id
           }).value,
           scope.organizationID != rootID {
            scope = .organization(rootID)
            reloadToken += 1
            await load()
        }
        section = .organizations
        selection.organizationID = id
        recordNavigation(from: previousLocation)
        persistNavigation()
    }

    func openContact(_ id: UUID) async {
        await openResource(id, in: .contacts, selection: \.contactID)
    }

    func openProject(_ id: UUID) async {
        await openResource(id, in: .projects, selection: \.projectID)
    }

    func openTopic(_ id: UUID) async {
        await openResource(id, in: .topics, selection: \.topicID)
    }

    func openInsight(_ id: UUID) async {
        await openResource(id, in: .insights, selection: \.insightID)
    }

    func createRootOrganization(name: String) async -> Bool {
        guard let dbQueue, let vaultID, name.nilIfBlank != nil else { return false }
        let previousLocation = currentLocation
        do {
            let organization = try await Task.detached(priority: .userInitiated) {
                try MeetingRepository(dbQueue: dbQueue).createOrganization(
                    vaultId: vaultID,
                    parentOrganizationId: nil,
                    nodeKind: .organization,
                    name: name
                )
            }.value
            scope = .organization(organization.id)
            section = .organizations
            selection.organizationID = organization.id
            recordNavigation(from: previousLocation)
            persistNavigation()
            await refreshAfterMutation()
            return true
        } catch {
            setError(error)
            return false
        }
    }

    func goBack() async {
        guard canGoBack, let location = backHistory.popLast() else { return }
        let previousLocation = currentLocation
        isNavigatingHistory = true
        defer { isNavigatingHistory = false }
        appendToHistory(&forwardHistory, location: previousLocation)
        await restoreNavigation(location)
    }

    func goForward() async {
        guard canGoForward, let location = forwardHistory.popLast() else { return }
        let previousLocation = currentLocation
        isNavigatingHistory = true
        defer { isNavigatingHistory = false }
        appendToHistory(&backHistory, location: previousLocation)
        await restoreNavigation(location)
    }

    func refreshAfterMutation() async {
        guard let vaultID else { return }
        DahliaWorkspaceChangeNotification.post(vaultID: vaultID, senderID: notificationSenderID)
        reloadToken += 1
        await load()
    }

    private var currentLocation: NavigationLocation {
        NavigationLocation(
            section: section,
            scope: scope,
            selection: selection
        )
    }

    private func openResource(
        _ id: UUID,
        in section: CustomerIntelligenceSection,
        selection selectionKeyPath: WritableKeyPath<CustomerIntelligenceSelection, UUID?>
    ) async {
        let previousLocation = currentLocation
        await ensureScopeContains(section: section, resourceID: id)
        self.section = section
        selection[keyPath: selectionKeyPath] = id
        recordNavigation(from: previousLocation)
        persistNavigation()
    }

    private func recordNavigation(from previousLocation: NavigationLocation) {
        guard !isNavigatingHistory, previousLocation != currentLocation else { return }
        appendToHistory(&backHistory, location: previousLocation)
        forwardHistory = []
    }

    private func appendToHistory(
        _ history: inout [NavigationLocation],
        location: NavigationLocation
    ) {
        if history.last != location {
            history.append(location)
        }
        if history.count > 50 {
            history.removeFirst(history.count - 50)
        }
    }

    private func restoreNavigation(_ location: NavigationLocation) async {
        let scopeChanged = scope != location.scope
        section = location.section
        scope = location.scope
        selection = location.selection
        persistNavigation()
        guard scopeChanged else { return }
        overview = .empty
        reloadToken += 1
        await load()
    }

    private func reconcileScope() {
        guard let id = scope.organizationID else { return }
        if !roots.contains(where: { $0.id == id }) {
            scope = .all
            selection.organizationID = nil
            persistNavigation()
        }
    }

    private func ensureScopeContains(
        section: CustomerIntelligenceSection,
        resourceID: UUID
    ) async {
        guard scope.organizationID != nil, let dbQueue, let vaultID else { return }
        let currentScope = scope
        do {
            let isVisible = try await Task.detached(priority: .userInitiated) {
                try MeetingRepository(dbQueue: dbQueue).customerIntelligenceScopeContains(
                    section: section,
                    resourceID: resourceID,
                    vaultId: vaultID,
                    scope: currentScope
                )
            }.value
            guard scope == currentScope, !isVisible else { return }
            scope = .all
            selection = CustomerIntelligenceSelection()
            overview = .empty
            reloadToken += 1
            persistNavigation()
            await load()
        } catch {
            setError(error)
        }
    }

    private func persistNavigation() {
        AppSettings.shared.customerIntelligenceSectionRawValue = section.rawValue
        AppSettings.shared.customerIntelligenceScopeRawValue = scope.organizationID?.uuidString ?? ""
    }

    private func observeWorkspaceChanges() {
        guard let vaultID else { return }
        notificationObserver = DistributedNotificationCenter.default().addObserver(
            forName: DahliaWorkspaceChangeNotification.name(vaultID: vaultID),
            object: nil,
            queue: .main
        ) { [weak self, notificationSenderID] notification in
            guard notification.object as? String != notificationSenderID else { return }
            let isSectionMutation = (notification.object as? String)?
                .hasPrefix(Self.sectionMutationSenderPrefix) == true
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !isSectionMutation {
                    reloadToken += 1
                }
                await load()
            }
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
