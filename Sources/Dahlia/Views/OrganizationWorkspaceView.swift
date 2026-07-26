import DahliaRuntimeSupport
import SwiftUI

// swiftlint:disable:next type_body_length
struct OrganizationWorkspaceView: View {
    var sidebarViewModel: SidebarViewModel
    var chatCoordinator: CodexChatCoordinator

    @State private var model: OrganizationWorkspaceViewModel
    @State private var zoom: CGFloat = 1
    @State private var canvasViewportSize: CGSize = .zero
    @State private var showsAIScope = false
    @State private var editedOrganizationName = ""
    @State private var provisionalName = ""
    @State private var departmentName = ""
    @State private var organizationName = ""
    @State private var selectedParentID: UUID?
    @State private var selectedMemberID: UUID?
    @State private var selectedUnassignedContactID: UUID?
    @State private var memberName = ""
    @State private var memberRole = ""
    @State private var selectedTopicForEditID: UUID?
    @State private var topicState = ""
    @State private var selectedProposalIDs: Set<UUID> = []

    init(sidebarViewModel: SidebarViewModel, chatCoordinator: CodexChatCoordinator) {
        self.sidebarViewModel = sidebarViewModel
        self.chatCoordinator = chatCoordinator
        _model = State(initialValue: OrganizationWorkspaceViewModel(
            dbQueue: sidebarViewModel.dbQueue,
            vaultID: sidebarViewModel.currentVault?.id
        ))
    }

    var body: some View {
        NavigationSplitView {
            organizationSidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } content: {
            canvasColumn
                .navigationSplitViewColumnWidth(min: 460, ideal: 760)
        } detail: {
            inspector
                .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 520)
        }
        .navigationTitle(L10n.organizations)
        .disabled(model.isMutating)
        .onChange(of: sidebarViewModel.currentVault?.id) { _, id in
            Task { await model.changeVault(to: id) }
        }
        .onChange(of: model.proposals.map(\.id)) { _, proposalIDs in
            selectedProposalIDs.formIntersection(proposalIDs)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    zoom = max(0.5, zoom - 0.1)
                } label: {
                    Label(L10n.zoomOut, systemImage: "minus.magnifyingglass")
                }
                .disabled(zoom <= 0.5)

                Text("\(Int(zoom * 100))%")
                    .monospacedDigit()
                    .frame(minWidth: 44)

                Button {
                    zoom = min(2, zoom + 0.1)
                } label: {
                    Label(L10n.zoomIn, systemImage: "plus.magnifyingglass")
                }
                .disabled(zoom >= 2)

                Button(L10n.fitToView, systemImage: "arrow.up.left.and.arrow.down.right") {
                    fitCanvas()
                }

                Button(L10n.organizeWithAI, systemImage: "sparkles") {
                    showsAIScope = true
                }
                .disabled(model.selectedRootID == nil)
            }
        }
        .task { await model.load() }
        .sheet(isPresented: $showsAIScope) {
            OrganizationAIScopeView(
                organizationID: model.selectedNodeID ?? model.selectedRootID,
                projects: sidebarViewModel.flatProjects,
                onPrepare: prepareAIRequest
            )
        }
        .alert(
            L10n.organizationWorkspaceError,
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button(L10n.close, role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert(item: $model.pendingContactDeletion) { pending in
            Alert(
                title: Text(L10n.deleteProvisionalPerson),
                message: Text(L10n.contactDeletionImpact(pending.impact)),
                primaryButton: .destructive(Text(L10n.delete)) {
                    Task { await model.confirmContactDeletion() }
                },
                secondaryButton: .cancel()
            )
        }
        .alert(item: $model.pendingOrganizationDeletion) { pending in
            Alert(
                title: Text(L10n.deleteOrganization),
                message: Text(L10n.organizationDeletionImpact(pending.impact)),
                primaryButton: .destructive(Text(L10n.delete)) {
                    Task { await model.confirmOrganizationDeletion() }
                },
                secondaryButton: .cancel()
            )
        }
        .alert(item: $model.pendingTopicDeletion) { pending in
            Alert(
                title: Text(L10n.deleteTopic),
                message: Text(L10n.topicDeletionImpact(pending.impact)),
                primaryButton: .destructive(Text(L10n.delete)) {
                    Task { await model.confirmTopicDeletion() }
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var organizationSidebar: some View {
        List(selection: Binding(
            get: { model.selectedRootID },
            set: { id in
                guard let id else { return }
                Task { await model.selectRoot(id) }
            }
        )) {
            Section(L10n.organizations) {
                ForEach(model.filteredRoots) { root in
                    Label(root.organization.name, systemImage: "building.2")
                        .tag(root.id)
                }
                HStack {
                    TextField(L10n.newOrganization, text: $organizationName)
                    Button(L10n.create) {
                        let name = organizationName
                        organizationName = ""
                        Task { await model.createRootOrganization(name: name) }
                    }
                    .disabled(organizationName.nilIfBlank == nil)
                }
            }
            if !model.unassignedContacts.isEmpty {
                Section(L10n.unassignedPeople) {
                    ForEach(model.unassignedContacts) { contact in
                        Label(
                            contact.displayName ?? contact.email ?? L10n.unnamedPerson,
                            systemImage: contact.isProvisional ? "person.crop.circle.badge.questionmark" : "person.crop.circle"
                        )
                    }
                }
            }
        }
        .searchable(text: $model.searchText, prompt: L10n.searchOrganizations)
        .onSubmit(of: .search) {
            Task { await model.searchAndRevealFirstMatch() }
        }
        .overlay {
            if model.roots.isEmpty, !model.isLoading {
                ContentUnavailableView(
                    L10n.noOrganizations,
                    systemImage: "building.2",
                    description: Text(L10n.noOrganizationsDescription)
                )
            }
        }
    }

    private var canvasColumn: some View {
        VStack(spacing: 0) {
            HStack {
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
                    peopleSection(detail)
                    projectsSection(detail)
                    topicsSection(detail)
                    meetingsSection(detail)
                }
                if !model.selectedTopicEvidence.isEmpty {
                    topicEvidenceSection
                }

                proposalSection
            }
            .task(id: "\(node.id.uuidString):\(node.organization.revision)") {
                editedOrganizationName = node.organization.name
                selectedParentID = node.organization.parentOrganizationId
                selectedMemberID = nil
                selectedUnassignedContactID = nil
                memberName = ""
                memberRole = ""
                selectedTopicForEditID = nil
                topicState = ""
            }
        } else {
            ContentUnavailableView(L10n.selectOrganization, systemImage: "building.2")
        }
    }

    private func organizationSection(_ node: OrganizationWorkspaceNode) -> some View {
        Section(L10n.department) {
            TextField(L10n.name, text: $editedOrganizationName)
            Button(L10n.save) {
                Task { await model.renameSelectedOrganization(to: editedOrganizationName) }
            }
            .disabled(editedOrganizationName.nilIfBlank == nil)

            Picker(L10n.parentDepartment, selection: $selectedParentID) {
                if node.organization.nodeKind == .organization {
                    Text(L10n.vaultRoot).tag(UUID?.none)
                }
                ForEach(parentCandidates(excluding: node.id)) { candidate in
                    Text(candidate.organization.name).tag(Optional(candidate.id))
                }
            }
            Button(L10n.move) {
                Task { await model.moveSelectedOrganization(to: selectedParentID) }
            }
            .disabled(selectedParentID == node.organization.parentOrganizationId)

            HStack {
                TextField(L10n.newDepartment, text: $departmentName)
                Button(L10n.create) {
                    let name = departmentName
                    departmentName = ""
                    Task { await model.createDepartment(name: name) }
                }
                .disabled(departmentName.nilIfBlank == nil)
            }
            Button(L10n.deleteOrganization, role: .destructive) {
                Task { await model.prepareOrganizationDeletion() }
            }
        }
    }

    private func peopleSection(_ detail: OrganizationWorkspaceDetail) -> some View {
        Section(L10n.people) {
            ForEach(detail.members) { member in
                contactRow(member)
            }
            HStack {
                TextField(L10n.provisionalPersonName, text: $provisionalName)
                Button(L10n.add) {
                    let name = provisionalName
                    provisionalName = ""
                    Task { await model.createProvisionalContact(name: name) }
                }
                .disabled(provisionalName.nilIfBlank == nil)
            }
            if !detail.members.isEmpty {
                Picker(L10n.person, selection: $selectedMemberID) {
                    Text(L10n.select).tag(UUID?.none)
                    ForEach(detail.members) { member in
                        Text(member.contact.displayName ?? member.contact.email ?? L10n.unnamedPerson)
                            .tag(Optional(member.id))
                    }
                }
                .onChange(of: selectedMemberID) { _, id in
                    let member = detail.members.first { $0.id == id }
                    memberName = member?.contact.displayName ?? ""
                    memberRole = member?.roleLabel ?? ""
                }
                if let member = detail.members.first(where: { $0.id == selectedMemberID }),
                   member.contact.isProvisional {
                    HStack {
                        TextField(L10n.name, text: $memberName)
                        Button(L10n.rename) {
                            Task { await model.renameProvisionalContact(member.contact, to: memberName) }
                        }
                        .disabled(memberName.nilIfBlank == nil)
                    }
                }
                HStack {
                    TextField(L10n.role, text: $memberRole)
                    Button(L10n.save) {
                        guard let contactID = selectedMemberID else { return }
                        Task { await model.setMemberRole(contactID: contactID, role: memberRole) }
                    }
                    .disabled(selectedMemberID == nil)
                }
            }
            if !model.unassignedContacts.isEmpty {
                HStack {
                    Picker(L10n.unassignedPeople, selection: $selectedUnassignedContactID) {
                        Text(L10n.select).tag(UUID?.none)
                        ForEach(model.unassignedContacts) { contact in
                            Text(contact.displayName ?? contact.email ?? L10n.unnamedPerson)
                                .tag(Optional(contact.id))
                        }
                    }
                    Button(L10n.addToDepartment) {
                        guard let contactID = selectedUnassignedContactID else { return }
                        Task { await model.assignUnassignedContact(contactID) }
                    }
                    .disabled(selectedUnassignedContactID == nil)
                }
            }
        }
    }

    private func contactRow(_ member: OrganizationWorkspaceMember) -> some View {
        let contact = member.contact
        return HStack {
            VStack(alignment: .leading) {
                Text(contact.displayName ?? contact.email ?? L10n.unnamedPerson)
                if let email = contact.email {
                    Text(email).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(L10n.provisionalPerson).font(.caption).foregroundStyle(.orange)
                }
                if let roleLabel = member.roleLabel {
                    Text(roleLabel).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(L10n.removeFromDepartment, systemImage: "person.badge.minus") {
                Task { await model.removeMember(contact.id) }
            }
            .labelStyle(.iconOnly)
            if contact.isProvisional {
                Button(L10n.delete, systemImage: "trash", role: .destructive) {
                    Task { await model.prepareContactDeletion(contact) }
                }
                .labelStyle(.iconOnly)
            }
        }
    }

    private func projectsSection(_ detail: OrganizationWorkspaceDetail) -> some View {
        Section(L10n.projects) {
            ForEach(detail.projects, id: \.id) { project in
                Text(project.path)
            }
        }
    }

    private func topicsSection(_ detail: OrganizationWorkspaceDetail) -> some View {
        Section(L10n.topics) {
            ForEach(detail.topics) { topic in
                topicRow(topic)
            }
            if !detail.topics.isEmpty {
                Picker(L10n.topic, selection: $selectedTopicForEditID) {
                    Text(L10n.select).tag(UUID?.none)
                    ForEach(detail.topics) { topic in
                        Text(topic.topic.title).tag(Optional(topic.id))
                    }
                }
                .onChange(of: selectedTopicForEditID) { _, id in
                    topicState = detail.topics.first { $0.id == id }?.topic.currentState ?? ""
                }
                TextEditor(text: $topicState)
                    .frame(minHeight: 64)
                Button(L10n.saveTopicState) {
                    guard let topic = detail.topics.first(where: {
                        $0.id == selectedTopicForEditID
                    })?.topic else { return }
                    Task { await model.updateTopicState(topic, currentState: topicState) }
                }
                .disabled(selectedTopicForEditID == nil || topicState.nilIfBlank == nil)
            }
        }
    }

    private func topicRow(_ topic: ConversationTopicOverview) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(topic.topic.title).font(.headline)
                Text(topic.topic.currentState).foregroundStyle(.secondary)
                Text(L10n.topicDerivedSummary(
                    meetings: topic.meetingCount,
                    organizations: topic.organizationCount
                ))
                .font(.caption)
            }
            Spacer()
            Button(L10n.delete, systemImage: "trash", role: .destructive) {
                Task { await model.prepareTopicDeletion(topic.topic) }
            }
            .labelStyle(.iconOnly)
        }
    }

    private func meetingsSection(_ detail: OrganizationWorkspaceDetail) -> some View {
        Section(L10n.meetings) {
            ForEach(detail.recentMeetings, id: \.id) { meeting in
                VStack(alignment: .leading) {
                    Text(meeting.name)
                    Text(meeting.createdAt, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var topicEvidenceSection: some View {
        Section(L10n.topicMeetingEvidence) {
            ForEach(model.selectedTopicEvidence) { evidence in
                VStack(alignment: .leading, spacing: 3) {
                    Text(evidence.meeting.name)
                    Text(evidence.meeting.createdAt, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(evidence.note)
                        .font(.caption)
                }
            }
        }
    }

    private func parentCandidates(excluding nodeID: UUID) -> [OrganizationWorkspaceNode] {
        model.loadedNodes.values
            .filter { $0.id != nodeID && !isDescendant($0.id, of: nodeID) }
            .sorted {
                $0.organization.name.localizedCaseInsensitiveCompare($1.organization.name) == .orderedAscending
            }
    }

    private func isDescendant(_ candidateID: UUID, of nodeID: UUID) -> Bool {
        var currentID: UUID? = candidateID
        while let id = currentID, let node = model.loadedNodes[id] {
            guard node.organization.parentOrganizationId != nodeID else { return true }
            currentID = node.organization.parentOrganizationId
        }
        return false
    }

    private var proposalSection: some View {
        Section(L10n.proposals) {
            ForEach(model.proposals) { proposal in
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: Binding(
                        get: { selectedProposalIDs.contains(proposal.id) },
                        set: { isSelected in updateProposalSelection(proposal, isSelected: isSelected) }
                    )) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(proposal.proposal.operationType)
                            Text(proposal.proposal.staleReason ?? L10n.readyForReview)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if !proposal.dependencies.isEmpty {
                                Text(L10n.proposalDependencies(proposal.dependencies.count))
                                    .font(.caption2)
                                ForEach(proposal.dependencies, id: \.self) { dependencyID in
                                    Label(dependencyID.uuidString, systemImage: "arrow.turn.down.right")
                                        .font(.caption2)
                                }
                            }
                        }
                    }
                    ForEach(proposalSummaries(proposal.proposal), id: \.self) { summary in
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(proposal.evidence.indices, id: \.self) { index in
                        Text(evidenceSummary(proposal.evidence[index]))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            HStack {
                Button(L10n.apply) {
                    Task { await model.applyProposals(applicableProposals) }
                }
                .disabled(applicableProposals.count != selectedProposals.count || applicableProposals.isEmpty)
                Button(L10n.reject) {
                    Task { await model.rejectProposals(selectedProposals) }
                }
                .disabled(selectedProposalIDs.isEmpty)
            }
        }
    }

    private var selectedProposals: [CustomerIntelligenceProposalOverview] {
        model.proposals.filter { selectedProposalIDs.contains($0.id) }
    }

    private var applicableProposals: [CustomerIntelligenceProposalOverview] {
        selectedProposals.filter { $0.proposal.status == .proposed }
    }

    private func updateProposalSelection(
        _ proposal: CustomerIntelligenceProposalOverview,
        isSelected: Bool
    ) {
        if isSelected {
            selectedProposalIDs.insert(proposal.id)
            var pending = proposal.dependencies
            while let dependencyID = pending.popLast() {
                guard selectedProposalIDs.insert(dependencyID).inserted,
                      let dependency = model.proposals.first(where: { $0.id == dependencyID })
                else { continue }
                pending.append(contentsOf: dependency.dependencies)
            }
        } else {
            var pending = [proposal.id]
            while let removedID = pending.popLast() {
                guard selectedProposalIDs.remove(removedID) != nil else { continue }
                pending.append(contentsOf: model.proposals.filter {
                    selectedProposalIDs.contains($0.id) && $0.dependencies.contains(removedID)
                }.map(\.id))
            }
        }
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
        chatCoordinator.showFloating()
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
        zoom = min(2, max(0.5, min(horizontal, vertical)))
    }

    private func proposalSummaries(_ record: CustomerIntelligenceProposalRecord) -> [String] {
        guard let payload = try? JSONDecoder().decode(
            CustomerIntelligenceProposalPayload.self,
            from: Data(record.payloadJSON.utf8)
        ) else {
            return []
        }
        let summaries = payload.expectations.map { expectation in
            let newValue = proposalValue(
                for: expectation.field,
                payload: payload
            )
            return "\(expectation.field): \(expectation.value ?? "∅") → \(newValue ?? "∅")"
        }
        if !summaries.isEmpty {
            return summaries
        }
        return [payload.name ?? payload.title ?? payload.currentState ?? payload.email ?? payload.roleLabel]
            .compactMap(\.self)
    }

    private func proposalValue(
        for field: String,
        payload: CustomerIntelligenceProposalPayload
    ) -> String? {
        switch field {
        case "name", "display_name":
            payload.name
        case "parent_organization_id":
            payload.parentOrganizationID?.uuidString
        case "email":
            payload.email
        case "role_label":
            payload.roleLabel
        case "title":
            payload.title
        case "current_state":
            payload.currentState
        case "references":
            payload.references.map { L10n.proposalReferences($0.count) }
        default:
            nil
        }
    }

    private func evidenceSummary(_ evidence: CustomerIntelligenceProposalEvidenceRecord) -> String {
        [evidence.resourceType, evidence.resourceId.uuidString, evidence.note]
            .compactMap(\.self)
            .joined(separator: " · ")
    }
}
