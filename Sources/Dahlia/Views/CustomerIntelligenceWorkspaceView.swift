import GRDB
import SwiftUI

struct OrganizationWorkspaceView: View {
    var sidebarViewModel: SidebarViewModel
    var chatCoordinator: CodexChatCoordinator
    var mainWindowNavigation: MainWindowNavigation

    @State private var model: CustomerIntelligenceWorkspaceViewModel
    @State private var showsInspector = true
    @State private var showsAIScope = false
    @State private var creationRequest: CustomerIntelligenceCreationRequest?

    init(
        sidebarViewModel: SidebarViewModel,
        chatCoordinator: CodexChatCoordinator,
        mainWindowNavigation: MainWindowNavigation
    ) {
        self.sidebarViewModel = sidebarViewModel
        self.chatCoordinator = chatCoordinator
        self.mainWindowNavigation = mainWindowNavigation
        _model = State(initialValue: CustomerIntelligenceWorkspaceViewModel(
            dbQueue: sidebarViewModel.dbQueue,
            vaultID: sidebarViewModel.currentVault?.id
        ))
    }

    var body: some View {
        NavigationSplitView {
            CustomerIntelligenceSidebar(
                selection: Binding(
                    get: { model.section },
                    set: { model.selectSection($0) }
                ),
                unacceptedInsightCount: model.counts.unacceptedInsights,
                canGoBack: model.canGoBack,
                canGoForward: model.canGoForward,
                onGoBack: { Task { await model.goBack() } },
                onGoForward: { Task { await model.goForward() } }
            )
            .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
        } detail: {
            workspaceDetail
        }
        .navigationTitle(L10n.customerIntelligence)
        .toolbar {
            CustomerIntelligenceToolbar(
                section: model.section,
                scope: model.scope,
                selectedOrganizationID: model.selection.organizationID,
                roots: model.roots,
                showsInspector: $showsInspector,
                onSelectScope: { scope in
                    Task { await model.selectScope(scope) }
                },
                onCreate: { creationRequest = $0 },
                onOrganizeWithAI: { showsAIScope = true }
            )
        }
        .task { await model.load() }
        .onChange(of: sidebarViewModel.currentVault?.id) { _, vaultID in
            creationRequest = nil
            showsAIScope = false
            Task {
                await model.changeVault(to: vaultID, dbQueue: sidebarViewModel.dbQueue)
            }
        }
        .sheet(item: $creationRequest) { request in
            CustomerIntelligenceCreationSheet(
                request: request,
                roots: model.roots,
                scope: model.scope,
                sidebarViewModel: sidebarViewModel,
                onCreateOrganization: createOrganization,
                onCreateContact: createContact,
                onCreateProject: createProject,
                onCreateTopic: createTopic
            )
        }
        .sheet(isPresented: $showsAIScope) {
            OrganizationAIScopeView(
                organizationID: model.scope.organizationID,
                projects: sidebarViewModel.flatProjects,
                onPrepare: prepareAIRequest
            )
        }
        .customerIntelligenceErrorAlert(message: $model.errorMessage)
    }

    @ViewBuilder
    private var workspaceDetail: some View {
        if let dbQueue = sidebarViewModel.dbQueue, let vaultID = sidebarViewModel.currentVault?.id {
            switch model.section {
            case .overview:
                CustomerIntelligenceOverviewView(
                    overview: model.overview,
                    scope: model.scope,
                    roots: model.roots,
                    isLoading: model.isLoading,
                    onSelectScope: { scope in Task { await model.selectScope(scope) } },
                    onOpenSection: { model.selectSection($0) },
                    onOpenContact: { id in Task { await model.openContact(id) } },
                    onOpenProject: { id in Task { await model.openProject(id) } },
                    onOpenTopic: { id in Task { await model.openTopic(id) } },
                    onOpenInsight: { id in Task { await model.openInsight(id) } },
                    onOpenMeetings: {
                        mainWindowNavigation.recordNavigation(to: .upcomingSchedule)
                        mainWindowNavigation.openMeetings()
                    },
                    onOpenMeeting: { openMeeting($0) }
                )
            case .organizations:
                organizationsView
            case .contacts:
                CustomerIntelligenceContactsView(
                    dbQueue: dbQueue,
                    vaultID: vaultID,
                    scope: model.scope,
                    initialContactID: model.selection.contactID,
                    reloadToken: model.reloadToken,
                    showsInspector: $showsInspector,
                    onSelectContact: model.updateContactSelection,
                    onOpenTopic: { id in Task { await model.openTopic(id) } },
                    onOpenProject: { id in Task { await model.openProject(id) } },
                    onOpenOrganization: { id in Task { await model.openOrganization(id) } },
                    onOpenMeeting: { openMeeting($0) }
                )
                .id("contacts:\(vaultID):\(model.scope)")
            case .projects:
                CustomerIntelligenceProjectsView(
                    dbQueue: dbQueue,
                    vaultID: vaultID,
                    scope: model.scope,
                    initialProjectID: model.selection.projectID,
                    reloadToken: model.reloadToken,
                    showsInspector: $showsInspector,
                    sidebarViewModel: sidebarViewModel,
                    onSelectProject: model.updateProjectSelection,
                    onOpenResource: { openResource($0) },
                    onOpenMeeting: { openMeeting($0) },
                    onOpenProjectManager: {
                        mainWindowNavigation.openProjects()
                    }
                )
                .id("projects:\(vaultID):\(model.scope)")
            case .topics:
                CustomerIntelligenceTopicsView(
                    dbQueue: dbQueue,
                    vaultID: vaultID,
                    scope: model.scope,
                    initialTopicID: model.selection.topicID,
                    reloadToken: model.reloadToken,
                    showsInspector: $showsInspector,
                    onSelectTopic: model.updateTopicSelection,
                    onOpenResource: { openResource($0) },
                    onOpenMeeting: { openMeeting($0) }
                )
                .id("topics:\(vaultID):\(model.scope)")
            case .insights:
                CustomerIntelligenceInsightsView(
                    dbQueue: dbQueue,
                    vaultID: vaultID,
                    scope: model.scope,
                    initialInsightID: model.selection.insightID,
                    reloadToken: model.reloadToken,
                    showsInspector: $showsInspector,
                    onSelectInsight: model.updateInsightSelection,
                    onOpenResource: { openResource($0) }
                )
                .id("insights:\(vaultID):\(model.scope)")
            }
        } else {
            ContentUnavailableView(
                L10n.customerIntelligenceNoVault,
                systemImage: "externaldrive"
            )
        }
    }

    @ViewBuilder
    private var organizationsView: some View {
        switch model.scope {
        case .all:
            CustomerIntelligenceOrganizationsGallery(
                customers: model.overview.customers,
                isLoading: model.isLoading,
                onOpen: { id in
                    Task { await model.selectScope(.organization(id)) }
                }
            )
        case let .organization(rootID):
            OrganizationHierarchyView(
                sidebarViewModel: sidebarViewModel,
                rootOrganizationID: rootID,
                initialOrganizationID: model.selection.organizationID,
                showsInspector: $showsInspector,
                onSelectOrganization: { model.selection.organizationID = $0 },
                onOpenContact: { id in Task { await model.openContact(id) } },
                onOpenProject: { id in Task { await model.openProject(id) } },
                onOpenTopic: { id in Task { await model.openTopic(id) } },
                onOpenAllTopics: { _ in model.selectSection(.topics) },
                onOpenMeeting: { openMeeting($0) }
            )
            .id(rootID)
        }
    }
}

private extension OrganizationWorkspaceView {
    private func openResource(_ resource: CustomerIntelligenceWorkspaceData.ResourceLink) {
        switch resource.kind {
        case .organization:
            Task { await model.openOrganization(resource.resourceID) }
        case .contact:
            Task { await model.openContact(resource.resourceID) }
        case .project:
            Task { await model.openProject(resource.resourceID) }
        case .topic:
            Task { await model.openTopic(resource.resourceID) }
        case .meeting:
            openMeeting(resource.resourceID)
        }
    }

    private func openMeeting(_ meetingID: UUID) {
        mainWindowNavigation.openMeetings()
        sidebarViewModel.selectMeeting(meetingID)
    }

    private func createOrganization(name: String, parentID: UUID?, description: String) async -> Bool {
        guard let parentID else {
            return await model.createRootOrganization(name: name, description: description)
        }
        guard let dbQueue = sidebarViewModel.dbQueue, let vaultID = sidebarViewModel.currentVault?.id else {
            return false
        }
        do {
            let organization = try await Task.detached(priority: .userInitiated) {
                try MeetingRepository(dbQueue: dbQueue).createOrganization(
                    vaultId: vaultID,
                    parentOrganizationId: parentID,
                    nodeKind: .unit,
                    name: name,
                    description: description
                )
            }.value
            model.selection.organizationID = organization.id
            await model.refreshAfterMutation()
            return true
        } catch {
            model.errorMessage = error.localizedDescription
            return false
        }
    }

    private func createContact(displayName: String, email: String, organizationID: UUID?) async -> Bool {
        guard let dbQueue = sidebarViewModel.dbQueue, let vaultID = sidebarViewModel.currentVault?.id else {
            return false
        }
        let contactModel = CustomerIntelligenceContactsViewModel(
            dbQueue: dbQueue,
            vaultID: vaultID,
            scope: model.scope
        )
        guard let id = await contactModel.create(
            displayName: displayName,
            email: email,
            organizationID: organizationID
        ) else {
            model.errorMessage = contactModel.errorMessage
            return false
        }
        await model.openContact(id)
        await model.refreshAfterMutation()
        return true
    }

    private func createProject(
        name: String,
        parentID: UUID?,
        type: ProjectType,
        description: String,
        organizationID: UUID
    ) async -> Bool {
        guard let dbQueue = sidebarViewModel.dbQueue,
              let vaultID = sidebarViewModel.currentVault?.id else {
            return false
        }
        do {
            let project = try await Task.detached(priority: .userInitiated) {
                try MeetingRepository(dbQueue: dbQueue).createCustomerIntelligenceProject(
                    vaultId: vaultID,
                    parentProjectId: parentID,
                    name: name,
                    description: description,
                    projectType: parentID == nil ? type : nil,
                    organizationId: organizationID
                )
            }.value
            await model.openProject(project.id)
            await model.refreshAfterMutation()
            return true
        } catch {
            model.errorMessage = error.localizedDescription
            return false
        }
    }

    private func createTopic(title: String, state: String, organizationID: UUID) async -> Bool {
        guard let dbQueue = sidebarViewModel.dbQueue, let vaultID = sidebarViewModel.currentVault?.id else {
            return false
        }
        let topicModel = CustomerIntelligenceTopicsViewModel(
            dbQueue: dbQueue,
            vaultID: vaultID,
            scope: model.scope
        )
        guard let id = await topicModel.create(
            title: title,
            currentState: state,
            organizationID: organizationID
        ) else {
            model.errorMessage = topicModel.errorMessage
            return false
        }
        await model.openTopic(id)
        await model.refreshAfterMutation()
        return true
    }

    private func prepareAIRequest(days: Int, projectID: UUID?, organizationID: UUID) {
        let end = Date.now
        let start = Calendar.current.date(byAdding: .day, value: -days, to: end) ?? end
        let formatter = ISO8601DateFormatter()
        let prompt = L10n.organizationAIPrompt(
            organizationID: organizationID,
            projectID: projectID,
            start: formatter.string(from: start),
            end: formatter.string(from: end)
        )
        if let draft = chatCoordinator.floatingSession.draft.nilIfBlank {
            chatCoordinator.floatingSession.draft = "\(draft)\n\n\(prompt)"
        } else {
            chatCoordinator.floatingSession.draft = prompt
        }
        MainWindowOpener.shared.openMainWindow()
        chatCoordinator.showFloating()
    }
}
