import DahliaRuntimeSupport
import SwiftUI

// swiftlint:disable:next type_body_length
struct OrganizationHierarchyView: View {
    var sidebarViewModel: SidebarViewModel
    let rootOrganizationID: UUID
    let initialOrganizationID: UUID?
    @Binding var showsInspector: Bool
    let onSelectOrganization: (UUID) -> Void
    let onOpenContact: (UUID) -> Void
    let onOpenProject: (UUID) -> Void
    let onOpenTopic: (UUID) -> Void
    let onOpenAllTopics: (UUID) -> Void
    let onOpenMeeting: (UUID) -> Void

    @State private var model: OrganizationWorkspaceViewModel
    @State private var zoom: CGFloat = 1
    @State private var canvasViewportSize: CGSize = .zero
    @State private var organizationBeingEdited: OrganizationWorkspaceNode?
    @State private var showsPersonAdditionSheet = false
    @State private var domainAdditionTarget: OrganizationRecord?

    init(
        sidebarViewModel: SidebarViewModel,
        rootOrganizationID: UUID,
        initialOrganizationID: UUID?,
        showsInspector: Binding<Bool>,
        onSelectOrganization: @escaping (UUID) -> Void,
        onOpenContact: @escaping (UUID) -> Void,
        onOpenProject: @escaping (UUID) -> Void,
        onOpenTopic: @escaping (UUID) -> Void,
        onOpenAllTopics: @escaping (UUID) -> Void,
        onOpenMeeting: @escaping (UUID) -> Void
    ) {
        self.sidebarViewModel = sidebarViewModel
        self.rootOrganizationID = rootOrganizationID
        self.initialOrganizationID = initialOrganizationID
        _showsInspector = showsInspector
        self.onSelectOrganization = onSelectOrganization
        self.onOpenContact = onOpenContact
        self.onOpenProject = onOpenProject
        self.onOpenTopic = onOpenTopic
        self.onOpenAllTopics = onOpenAllTopics
        self.onOpenMeeting = onOpenMeeting
        _model = State(initialValue: OrganizationWorkspaceViewModel(
            dbQueue: sidebarViewModel.dbQueue,
            vaultID: sidebarViewModel.currentVault?.id
        ))
    }

    var body: some View {
        canvasColumn
            .frame(minWidth: 460, idealWidth: 760)
            .inspector(isPresented: $showsInspector) {
                VStack(spacing: 0) {
                    inspector
                }
                .inspectorColumnWidth(min: 300, ideal: 380, max: 520)
                .alert(item: $model.pendingDeletion, content: deletionAlert)
            }
            .disabled(model.isMutating)
            .onChange(of: sidebarViewModel.currentVault?.id) { _, id in
                Task { await model.changeVault(to: id) }
            }
            .onChange(of: rootOrganizationID) { _, id in
                Task {
                    await model.selectRoot(id)
                    if let initialOrganizationID, initialOrganizationID != id {
                        await model.revealOrganization(initialOrganizationID)
                    }
                }
            }
            .onChange(of: initialOrganizationID) { _, id in
                if let id {
                    Task { await model.revealOrganization(id) }
                }
            }
            .onChange(of: model.selectedNodeID) { _, id in
                if let id {
                    onSelectOrganization(id)
                }
            }
            .task {
                await model.load(selectingRootID: rootOrganizationID)
                if let initialOrganizationID, initialOrganizationID != rootOrganizationID {
                    await model.revealOrganization(initialOrganizationID)
                }
            }
            .sheet(item: $organizationBeingEdited) { node in
                OrganizationEditorSheet(
                    organization: node,
                    parentCandidates: parentCandidates(excluding: node.id),
                    onSave: model.updateSelectedOrganization
                )
            }
            .sheet(isPresented: $showsPersonAdditionSheet) {
                OrganizationMemberAdditionSheet(model: model)
            }
            .sheet(item: $domainAdditionTarget) { target in
                OrganizationDomainAdditionSheet(organizationName: target.name) {
                    await model.addDomain($0, to: target)
                }
            }
            .confirmationDialog(
                L10n.organizationDomainAlreadyUsed(by: model.pendingMerge?.preview.source.name ?? ""),
                isPresented: Binding(
                    get: { model.pendingMerge != nil },
                    set: { if !$0 { model.pendingMerge = nil } }
                ),
                presenting: model.pendingMerge
            ) { pending in
                Button(L10n.addAsSharedOrganizationDomain) {
                    Task { await model.confirmSharedDomain(pending) }
                }
                Button(L10n.mergeOrganizations, role: .destructive) {
                    Task { await model.confirmMerge(pending) }
                }
                Button(L10n.cancel, role: .cancel) {}
            } message: { pending in
                Text(L10n.organizationMergeImpact(
                    domainName: pending.preview.domainName,
                    targetName: pending.preview.target.name,
                    impact: pending.preview.impact
                ))
            }
            .customerIntelligenceErrorAlert(
                title: L10n.organizationWorkspaceError,
                message: $model.errorMessage
            )
    }

    private func deletionAlert(_ pending: OrganizationWorkspaceViewModel.PendingOrganizationDeletion) -> Alert {
        Alert(
            title: Text(L10n.deleteOrganization(named: pending.organization.name)),
            message: Text(L10n.organizationDeletionImpact(pending.impact)),
            primaryButton: .destructive(Text(L10n.delete)) {
                Task { await model.confirmDeletion(pending) }
            },
            secondaryButton: .cancel()
        )
    }

    private var canvasZoomControls: some View {
        HStack(spacing: 6) {
            Button(L10n.zoomOut, systemImage: "minus.magnifyingglass") {
                zoom = OrganizationCanvasZoom.clamped(zoom - OrganizationCanvasZoom.step)
            }
            .disabled(zoom <= OrganizationCanvasZoom.minimum)

            Text(zoom, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit()
                .frame(minWidth: 44)

            Button(L10n.zoomIn, systemImage: "plus.magnifyingglass") {
                zoom = OrganizationCanvasZoom.clamped(zoom + OrganizationCanvasZoom.step)
            }
            .disabled(zoom >= OrganizationCanvasZoom.maximum)

            Button(L10n.fitToView, systemImage: "arrow.up.left.and.arrow.down.right") {
                fitCanvas()
            }
        }
        .labelStyle(.iconOnly)
        .dahliaFixedSymbol()
        .buttonStyle(.borderless)
    }

    private var canvasColumn: some View {
        VStack(spacing: 0) {
            HStack {
                TextField(L10n.searchOrganizations, text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                    .onSubmit {
                        Task { await model.searchAndRevealFirstMatch() }
                    }
                Picker(L10n.topic, selection: Binding(
                    get: { model.selectedTopicID },
                    set: { id in Task { await model.selectTopic(id) } }
                )) {
                    Text(L10n.allTopics).tag(UUID?.none)
                    ForEach(model.allTopics) { topic in
                        Text(topic.topic.title).tag(Optional(topic.id))
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 320)
                Spacer()
                canvasZoomControls
                if model.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(10)

            Divider()
            GeometryReader { proxy in
                OrganizationCanvasView(model: model, zoom: $zoom)
                    .onAppear { canvasViewportSize = proxy.size }
                    .onChange(of: proxy.size) { _, size in canvasViewportSize = size }
            }
        }
    }

    @ViewBuilder
    private var inspector: some View {
        if let node = model.selectedNodeID.flatMap({ model.loadedNodes[$0] }) {
            List {
                organizationSection(node)

                if let detail = model.selectedDetail {
                    if node.organization.isRootOrganization {
                        domainsSection(detail, organization: node.organization)
                    }
                    peopleSection(detail)
                    if !detail.projects.isEmpty {
                        projectsSection(detail)
                    }
                    if !detail.topics.isEmpty {
                        topicsSection(detail)
                    }
                    if !detail.recentMeetings.isEmpty {
                        meetingsSection(detail)
                    }
                }
                if !model.selectedTopicEvidence.isEmpty {
                    topicEvidenceSection
                }

                OrganizationDeletionSection(
                    onRequestDeletion: requestOrganizationDeletion
                )
                .disabled(model.isLoading || model.isPreparingDeletion)
            }
        } else {
            ContentUnavailableView(L10n.selectOrganization, systemImage: "building.2")
        }
    }

    private func organizationSection(_ node: OrganizationWorkspaceNode) -> some View {
        Section(L10n.department) {
            LabeledContent(L10n.name, value: node.organization.name)
            if let description = node.organization.description.nilIfBlank {
                LabeledContent(L10n.organizationDescription) {
                    Text(description)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
            }
            if let parentID = node.organization.parentOrganizationId,
               let parent = model.loadedNodes[parentID] {
                LabeledContent(L10n.parentDepartment, value: parent.organization.name)
            }
            Button(organizationEditTitle(for: node), systemImage: "pencil") {
                organizationBeingEdited = node
            }
        }
    }

    private func domainsSection(
        _ detail: OrganizationWorkspaceDetail,
        organization: OrganizationRecord
    ) -> some View {
        Section(L10n.organizationDomains) {
            ForEach(detail.domains, id: \.domainName) { domain in
                HStack {
                    Text(domain.domainName)
                    Spacer()
                    if domain.isPrimary {
                        Text(L10n.primary)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Button(L10n.addOrganizationDomain, systemImage: "plus") {
                domainAdditionTarget = organization
            }
        }
    }

    private func requestOrganizationDeletion() {
        Task { await model.prepareOrganizationDeletion() }
    }

    private func peopleSection(_ detail: OrganizationWorkspaceDetail) -> some View {
        Section(L10n.people) {
            ForEach(detail.members) { member in
                contactRow(member)
            }
            Button(L10n.customerIntelligenceAddPerson, systemImage: "person.badge.plus") {
                showsPersonAdditionSheet = true
            }
        }
    }

    private func contactRow(_ member: OrganizationWorkspaceMember) -> some View {
        let contact = member.contact
        return HStack {
            Button {
                onOpenContact(contact.id)
            } label: {
                VStack(alignment: .leading) {
                    Text(contact.displayName ?? contact.email ?? L10n.unnamedPerson)
                    if let email = contact.email {
                        Text(email).dahliaFont(.secondary).foregroundStyle(.secondary)
                    } else {
                        Text(L10n.customerIntelligenceEmailNotSet)
                            .dahliaFont(.secondary)
                            .foregroundStyle(.secondary)
                    }
                    if let roleLabel = member.roleLabel {
                        Text(roleLabel).dahliaFont(.secondary).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }

    private func projectsSection(_ detail: OrganizationWorkspaceDetail) -> some View {
        Section(L10n.projects) {
            ForEach(detail.projects, id: \.id) { project in
                Button {
                    onOpenProject(project.id)
                } label: {
                    Label(project.path, systemImage: "folder")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func topicsSection(_ detail: OrganizationWorkspaceDetail) -> some View {
        Section(L10n.topics) {
            ForEach(Array(detail.topics.prefix(3))) { topic in
                topicRow(topic)
            }
            if detail.topics.count > 3, let organizationID = model.selectedNodeID {
                Button(L10n.customerIntelligenceShowAllTopics) {
                    onOpenAllTopics(organizationID)
                }
            }
        }
    }

    private func topicRow(_ topic: ConversationTopicOverview) -> some View {
        Button {
            onOpenTopic(topic.id)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(topic.topic.title).dahliaFont(.subsectionTitle, weight: .semibold)
                Text(topic.topic.currentState)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack {
                    Text(L10n.topicDerivedSummary(
                        meetings: topic.meetingCount,
                        organizations: topic.organizationCount
                    ))
                    if let date = topic.lastDiscussedAt {
                        Text(date, style: .date)
                    }
                }
                .dahliaFont(.secondary)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func meetingsSection(_ detail: OrganizationWorkspaceDetail) -> some View {
        Section(L10n.meetings) {
            ForEach(detail.recentMeetings, id: \.id) { meeting in
                Button {
                    onOpenMeeting(meeting.id)
                } label: {
                    VStack(alignment: .leading) {
                        Text(meeting.name)
                        Text(meeting.effectiveRecordingStartedAt, style: .date)
                            .dahliaFont(.secondary)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var topicEvidenceSection: some View {
        Section(L10n.topicMeetingEvidence) {
            ForEach(model.selectedTopicEvidence) { evidence in
                Button {
                    onOpenMeeting(evidence.meeting.id)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(evidence.meeting.name)
                        Text(evidence.meeting.effectiveRecordingStartedAt, style: .date)
                            .dahliaFont(.secondary)
                            .foregroundStyle(.secondary)
                        Text(evidence.note)
                            .dahliaFont(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func parentCandidates(excluding nodeID: UUID) -> [OrganizationRecord] {
        let organizationsByID = Dictionary(
            uniqueKeysWithValues: model.organizationCandidates.map { ($0.id, $0) }
        )
        return model.organizationCandidates
            .filter {
                $0.id != nodeID
                    && !isDescendant($0.id, of: nodeID, organizationsByID: organizationsByID)
            }
            .sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    private func organizationEditTitle(for node: OrganizationWorkspaceNode) -> String {
        node.organization.nodeKind == .organization
            ? L10n.customerIntelligenceEditOrganization
            : L10n.customerIntelligenceEditDepartment
    }

    private func isDescendant(
        _ candidateID: UUID,
        of nodeID: UUID,
        organizationsByID: [UUID: OrganizationRecord]
    ) -> Bool {
        var currentID: UUID? = candidateID
        while let id = currentID, let node = organizationsByID[id] {
            guard node.parentOrganizationId != nodeID else { return true }
            currentID = node.parentOrganizationId
        }
        return false
    }

    private func fitCanvas() {
        let content = model.canvasLayout.size
        guard content.width > 0, content.height > 0,
              canvasViewportSize.width > 0, canvasViewportSize.height > 0 else {
            zoom = 1
            return
        }
        let horizontal = max(canvasViewportSize.width - 32, 1) / content.width
        let vertical = max(canvasViewportSize.height - 32, 1) / content.height
        zoom = OrganizationCanvasZoom.clamped(min(horizontal, vertical))
    }

}
