import GRDB
import SwiftUI

struct CustomerIntelligenceContactsView: View {
    let initialContactID: UUID?
    let reloadToken: Int
    @Binding var showsInspector: Bool
    let onSelectContact: (UUID?) -> Void
    let onOpenTopic: (UUID) -> Void
    let onOpenProject: (UUID) -> Void
    let onOpenOrganization: (UUID) -> Void
    let onOpenMeeting: (UUID) -> Void

    @State private var model: CustomerIntelligenceContactsViewModel
    @State private var selectedContactID: UUID?
    @State private var editedContact: ContactRecord?
    @State private var managesMemberships = false
    @State private var sortOrder = [
        KeyPathComparator(\CustomerIntelligenceWorkspaceData.ContactSummary.sortName),
    ]
    @ObservedObject private var settings = AppSettings.shared

    init(
        dbQueue: DatabaseQueue,
        vaultID: UUID,
        scope: CustomerIntelligenceScope,
        initialContactID: UUID?,
        reloadToken: Int,
        showsInspector: Binding<Bool>,
        onSelectContact: @escaping (UUID?) -> Void,
        onOpenTopic: @escaping (UUID) -> Void,
        onOpenProject: @escaping (UUID) -> Void,
        onOpenOrganization: @escaping (UUID) -> Void,
        onOpenMeeting: @escaping (UUID) -> Void
    ) {
        self.initialContactID = initialContactID
        self.reloadToken = reloadToken
        _showsInspector = showsInspector
        self.onSelectContact = onSelectContact
        self.onOpenTopic = onOpenTopic
        self.onOpenProject = onOpenProject
        self.onOpenOrganization = onOpenOrganization
        self.onOpenMeeting = onOpenMeeting
        _model = State(initialValue: CustomerIntelligenceContactsViewModel(
            dbQueue: dbQueue,
            vaultID: vaultID,
            scope: scope
        ))
        _selectedContactID = State(initialValue: initialContactID)
    }

    var body: some View {
        VStack(spacing: 0) {
            CustomerIntelligenceContactFilterBar(filter: $model.filter)
            Divider()
            contactTable
        }
        .navigationTitle(L10n.people)
        .searchable(text: $model.searchText, prompt: L10n.customerIntelligenceSearchContacts)
        .inspector(isPresented: $showsInspector) {
            contactInspector
                .inspectorColumnWidth(min: 320, ideal: 390, max: 540)
        }
        .task(id: reloadToken) {
            selectedContactID = initialContactID ?? selectedContactID
            await model.load(selectedID: selectedContactID)
            reconcileSelection()
        }
        .onChange(of: initialContactID) { _, id in
            selectedContactID = id
        }
        .onChange(of: selectedContactID) { _, id in
            onSelectContact(id)
            Task { await model.select(id) }
        }
        .sheet(item: $editedContact) { contact in
            CustomerIntelligenceContactEditorSheet(contact: contact, model: model)
        }
        .sheet(isPresented: $managesMemberships) {
            CustomerIntelligenceMembershipSheet(model: model)
        }
        .alert(item: $model.pendingDeletion) { pending in
            Alert(
                title: Text(L10n.customerIntelligenceDeletePerson),
                message: Text(L10n.contactDeletionImpact(pending.impact)),
                primaryButton: .destructive(Text(L10n.delete)) {
                    Task {
                        if await model.confirmDeletion(pending) {
                            selectedContactID = nil
                        }
                    }
                },
                secondaryButton: .cancel()
            )
        }
        .customerIntelligenceErrorAlert(
            title: L10n.customerIntelligencePeopleError,
            message: $model.errorMessage
        )
    }

    private var contactTable: some View {
        Table(
            model.filteredContacts.sorted(using: sortOrder),
            selection: $selectedContactID,
            sortOrder: $sortOrder
        ) {
            TableColumn(L10n.name, value: \.sortName) { summary in
                HStack(spacing: 6) {
                    Text(summary.contact.displayName ?? summary.contact.email ?? L10n.unnamedPerson)
                        .lineLimit(1)
                }
            }
            TableColumn(L10n.customerIntelligenceEmail, value: \.sortEmail) { summary in
                if let email = summary.contact.email {
                    Text(email)
                        .lineLimit(1)
                } else {
                    Text(L10n.customerIntelligenceEmailNotSet)
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 150, ideal: 220)
            TableColumn(L10n.organizations, value: \.sortOrganizations) { summary in
                Text(summary.organizationNames.joined(separator: ", "))
                    .foregroundStyle(summary.organizationNames.isEmpty ? Color.secondary : Color.primary)
                    .lineLimit(1)
            }
            TableColumn(L10n.role, value: \.sortRoles) { summary in
                Text(summary.roleLabels.joined(separator: ", "))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            TableColumn(L10n.customerIntelligenceLastInteraction, value: \.sortLastInteraction) { summary in
                if let date = summary.lastInteractionAt {
                    Text(date, format: .dateTime.year().month().day())
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
            .width(min: 110, ideal: 130)
            TableColumn(L10n.meetings, value: \.meetingCount) { summary in
                Text(summary.meetingCount, format: .number)
                    .monospacedDigit()
            }
            .width(70)
            TableColumn(L10n.topics, value: \.topicCount) { summary in
                Text(summary.topicCount, format: .number)
                    .monospacedDigit()
            }
            .width(60)
        }
        .customerIntelligenceTableStyle()
        .environment(\.defaultMinListRowHeight, tableRowHeight)
        .overlay {
            if model.filteredContacts.isEmpty, !model.isLoading {
                if model.searchText.nilIfBlank != nil {
                    ContentUnavailableView.search
                } else {
                    ContentUnavailableView(
                        L10n.customerIntelligenceNoPeople,
                        systemImage: "person.2",
                        description: Text(L10n.customerIntelligenceNoPeopleDescription)
                    )
                }
            } else if model.isLoading, model.contacts.isEmpty {
                ProgressView()
            }
        }
    }

    @ViewBuilder
    private var contactInspector: some View {
        if let detail = model.detail {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    CustomerIntelligenceInspectorHeader(
                        title: detail.summary.contact.displayName
                            ?? detail.summary.contact.email
                            ?? L10n.unnamedPerson,
                        subtitle: detail.summary.contact.email,
                        systemImage: "person.crop.circle",
                        badge: detail.summary.contact.email == nil
                            ? L10n.customerIntelligenceEmailNotSet
                            : nil,
                        onEdit: { editedContact = detail.summary.contact }
                    )

                    CustomerIntelligenceInspectorSection(title: L10n.organizations) {
                        if detail.memberships.isEmpty {
                            Text(L10n.customerIntelligenceNoMemberships)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(detail.memberships) { membership in
                                CustomerIntelligenceLinkRow(
                                    title: membership.organization.name,
                                    subtitle: membership.roleLabel,
                                    systemImage: "building.2",
                                    action: { onOpenOrganization(membership.id) }
                                )
                            }
                        }
                        Button(L10n.customerIntelligenceManageMemberships, systemImage: "person.2.badge.gearshape") {
                            managesMemberships = true
                        }
                    }

                    if !detail.projects.isEmpty {
                        CustomerIntelligenceInspectorSection(title: L10n.projects) {
                            ForEach(detail.projects) { project in
                                CustomerIntelligenceLinkRow(
                                    title: project.title,
                                    subtitle: project.role,
                                    systemImage: "folder",
                                    action: { onOpenProject(project.resourceID) }
                                )
                            }
                        }
                    }

                    if !detail.topics.isEmpty {
                        CustomerIntelligenceInspectorSection(title: L10n.topics) {
                            ForEach(detail.topics) { topic in
                                CustomerIntelligenceLinkRow(
                                    title: topic.topic.title,
                                    subtitle: topic.topic.currentState,
                                    systemImage: "text.bubble",
                                    action: { onOpenTopic(topic.id) }
                                )
                            }
                        }
                    }

                    if !detail.recentMeetings.isEmpty {
                        CustomerIntelligenceInspectorSection(title: L10n.meetings) {
                            ForEach(detail.recentMeetings, id: \.id) { meeting in
                                CustomerIntelligenceLinkRow(
                                    title: meeting.name,
                                    subtitle: meeting.effectiveRecordingStartedAt.formatted(date: .abbreviated, time: .omitted),
                                    systemImage: "calendar",
                                    action: { onOpenMeeting(meeting.id) }
                                )
                            }
                        }
                    }

                    if detail.summary.contact.isProvisional {
                        CustomerIntelligenceDangerSection(
                            title: L10n.customerIntelligenceDeletePerson,
                            message: L10n.customerIntelligenceDeletePersonHelp,
                            action: { Task { await model.prepareDeletion(detail.summary.contact) } }
                        )
                    }
                }
                .padding()
            }
        } else {
            ContentUnavailableView(
                L10n.customerIntelligenceSelectContact,
                systemImage: "person.crop.circle"
            )
        }
    }

    private var tableRowHeight: Double {
        settings.customerIntelligenceTableDensityRawValue == CustomerIntelligenceTableDensity.compact.rawValue
            ? 24 : 34
    }

    private func reconcileSelection() {
        if let selectedContactID, model.contacts.contains(where: { $0.id == selectedContactID }) {
            return
        }
        selectedContactID = nil
    }
}

private struct CustomerIntelligenceMembershipSheet: View {
    @Environment(\.dismiss) private var dismiss

    let model: CustomerIntelligenceContactsViewModel

    @State private var selectedOrganizationID: UUID?
    @State private var roleLabel = ""

    var body: some View {
        NavigationStack {
            Form {
                if let errorMessage = model.errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }

                Section(L10n.customerIntelligenceExistingMemberships) {
                    if let memberships = model.detail?.memberships, !memberships.isEmpty {
                        ForEach(memberships) { membership in
                            LabeledContent {
                                Button(L10n.remove, systemImage: "minus.circle", role: .destructive) {
                                    Task { _ = await model.removeMembership(organizationID: membership.id) }
                                }
                                .labelStyle(.iconOnly)
                                .disabled(model.isSaving)
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(membership.organization.name)
                                    if let role = membership.roleLabel {
                                        Text(role)
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    } else {
                        Text(L10n.customerIntelligenceNoMemberships)
                            .foregroundStyle(.secondary)
                    }
                }

                Section(L10n.customerIntelligenceAddMembership) {
                    Picker(L10n.organizations, selection: $selectedOrganizationID) {
                        Text(L10n.select).tag(UUID?.none)
                        ForEach(availableOrganizations) { organization in
                            Text(organization.name).tag(Optional(organization.id))
                        }
                    }
                    TextField(L10n.role, text: $roleLabel)
                    Button(L10n.add) {
                        guard let selectedOrganizationID else { return }
                        Task {
                            if await model.setMembership(
                                organizationID: selectedOrganizationID,
                                roleLabel: roleLabel
                            ) {
                                self.selectedOrganizationID = nil
                                roleLabel = ""
                            }
                        }
                    }
                    .disabled(selectedOrganizationID == nil || model.isSaving)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(L10n.customerIntelligenceManageMemberships)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.done, action: dismiss.callAsFunction)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 520)
    }

    private var availableOrganizations: [OrganizationRecord] {
        let membershipIDs = Set(model.detail?.memberships.map(\.id) ?? [])
        return model.organizations.filter { !membershipIDs.contains($0.id) }
    }
}

private struct CustomerIntelligenceContactFilterBar: View {
    @Binding var filter: CustomerIntelligenceContactsViewModel.Filter

    var body: some View {
        Picker(L10n.filter, selection: $filter) {
            Text(L10n.all).tag(CustomerIntelligenceContactsViewModel.Filter.all)
            Text(L10n.unassignedPeople).tag(CustomerIntelligenceContactsViewModel.Filter.unassigned)
            Text(L10n.customerIntelligenceEmailNotSet)
                .tag(CustomerIntelligenceContactsViewModel.Filter.emailMissing)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 420)
        .padding()
    }
}

private struct CustomerIntelligenceContactEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let contact: ContactRecord
    let model: CustomerIntelligenceContactsViewModel

    @State private var displayName: String
    @State private var email: String

    init(contact: ContactRecord, model: CustomerIntelligenceContactsViewModel) {
        self.contact = contact
        self.model = model
        _displayName = State(initialValue: contact.displayName ?? "")
        _email = State(initialValue: contact.email ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                if let errorMessage = model.errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }

                Section(L10n.customerIntelligencePersonDetails) {
                    TextField(L10n.name, text: $displayName)
                    if contact.isProvisional {
                        TextField(L10n.customerIntelligenceEmail, text: $email)
                            .textContentType(.emailAddress)
                    } else if let email = contact.email {
                        LabeledContent(L10n.customerIntelligenceEmail, value: email)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(L10n.customerIntelligenceEditContact)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.cancel, action: dismiss.callAsFunction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.save) {
                        Task { await save() }
                    }
                    .disabled(displayName.nilIfBlank == nil || model.isSaving)
                }
            }
        }
        .frame(minWidth: 500, minHeight: 340)
        .alert(item: Binding(
            get: { model.pendingResolution },
            set: { model.pendingResolution = $0 }
        )) { pending in
            Alert(
                title: Text(L10n.customerIntelligenceMergeContactTitle),
                message: Text(L10n.customerIntelligenceMergeContactMessage(
                    pending.existing.displayName ?? pending.existing.email ?? L10n.unnamedPerson
                )),
                primaryButton: .destructive(Text(L10n.customerIntelligenceMerge)) {
                    Task {
                        if await model.confirmResolution(pending) {
                            dismiss()
                        }
                    }
                },
                secondaryButton: .cancel {
                    model.pendingResolution = nil
                }
            )
        }
    }

    private func save() async {
        guard await model.save(
            contact: contact,
            displayName: displayName,
            email: email
        ) else {
            return
        }
        dismiss()
    }
}
