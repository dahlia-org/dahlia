import SwiftUI

struct CustomerIntelligenceCreationSheet: View {
    @Environment(\.dismiss) private var dismiss

    let request: CustomerIntelligenceCreationRequest
    let roots: [OrganizationWorkspaceNode]
    let scope: CustomerIntelligenceScope
    let sidebarViewModel: SidebarViewModel
    let onCreateOrganization: (String, UUID?, String) async -> Bool
    let onCreateContact: (String, String, UUID?) async -> Bool
    let onCreateProject: (String, UUID?, ProjectType, String, UUID) async -> Bool
    let onCreateTopic: (String, String, UUID) async -> Bool

    @State private var name = ""
    @State private var email = ""
    @State private var details = ""
    @State private var selectedOrganizationID: UUID?
    @State private var selectedProjectParentID: UUID?
    @State private var projectType = ProjectType.customer
    @State private var organizationOptions: [OrganizationRecord] = []
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }

                fields
            }
            .formStyle(.grouped)
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.cancel, action: dismiss.callAsFunction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.create) {
                        Task { await submit() }
                    }
                    .disabled(!canSubmit || isSaving)
                }
            }
        }
        .frame(minWidth: 500, minHeight: sheetHeight)
        .task {
            selectedOrganizationID = request.initialOrganizationID ?? scope.organizationID ?? roots.first?.id
            await loadOrganizationOptions()
        }
    }

    @ViewBuilder
    private var fields: some View {
        switch request {
        case let .organization(parentID):
            Section {
                TextField(L10n.name, text: $name)
                TextField(L10n.organizationDescription, text: $details, axis: .vertical)
                    .lineLimit(4 ... 8)
                if parentID != nil {
                    organizationPicker(title: L10n.parentDepartment)
                        .disabled(true)
                }
            }
        case .contact:
            Section {
                TextField(L10n.name, text: $name)
                TextField(L10n.customerIntelligenceEmail, text: $email)
                    .textContentType(.emailAddress)
                organizationPicker(title: L10n.organizations, includesNone: true)
            } header: {
                Text(L10n.customerIntelligencePersonDetails)
            } footer: {
                Text(L10n.customerIntelligencePersonCreationHelp)
            }
        case .project:
            Section(L10n.project) {
                TextField(L10n.projectName, text: $name)
                Picker(L10n.parentProject, selection: $selectedProjectParentID) {
                    Text(L10n.vaultRoot).tag(UUID?.none)
                    ForEach(rootProjects) { project in
                        Text(project.projectName).tag(Optional(project.projectId))
                    }
                }
                if selectedProjectParentID == nil {
                    Picker(L10n.projectType, selection: $projectType) {
                        ForEach(ProjectType.allCases, id: \.self) { type in
                            Text(L10n.projectTypeName(type)).tag(type)
                        }
                    }
                }
                TextField(
                    L10n.projectDescription,
                    text: $details,
                    axis: .vertical
                )
                .lineLimit(4 ... 8)
                organizationPicker(title: L10n.customerIntelligenceCustomer)
            }
        case .topic:
            Section(L10n.topic) {
                TextField(L10n.customerIntelligenceTopicTitle, text: $name)
                TextField(
                    L10n.customerIntelligenceCurrentState,
                    text: $details,
                    axis: .vertical
                )
                .lineLimit(4 ... 8)
                organizationPicker(title: L10n.customerIntelligenceCustomer)
            }
        }
    }

    private func organizationPicker(title: String, includesNone: Bool = false) -> some View {
        let organizationsByID = Dictionary(
            uniqueKeysWithValues: organizationOptions.map { ($0.id, $0) }
        )
        return Picker(title, selection: $selectedOrganizationID) {
            if includesNone {
                Text(L10n.unassignedPeople).tag(UUID?.none)
            }
            ForEach(organizationOptions) { organization in
                Text(organizationLabel(organization, organizationsByID: organizationsByID))
                    .tag(Optional(organization.id))
            }
        }
    }

    private func organizationLabel(
        _ organization: OrganizationRecord,
        organizationsByID: [UUID: OrganizationRecord]
    ) -> String {
        var names = [organization.name]
        var parentID = organization.parentOrganizationId
        while let id = parentID, let parent = organizationsByID[id], names.count < 32 {
            names.append(parent.name)
            parentID = parent.parentOrganizationId
        }
        return names.reversed().joined(separator: " / ")
    }

    private func loadOrganizationOptions() async {
        guard let dbQueue = sidebarViewModel.dbQueue,
              let vaultID = sidebarViewModel.currentVault?.id else {
            organizationOptions = roots.map(\.organization)
            return
        }
        do {
            let rootID = scope.organizationID
            organizationOptions = try await Task.detached(priority: .userInitiated) {
                let repository = MeetingRepository(dbQueue: dbQueue)
                if let rootID {
                    return try repository.fetchOrganizationWorkspaceSubtree(
                        rootOrganizationId: rootID,
                        vaultId: vaultID
                    )
                }
                return try repository.fetchOrganizations(vaultId: vaultID)
            }.value
        } catch {
            organizationOptions = roots.map(\.organization)
            errorMessage = error.localizedDescription
        }
    }

    private var rootProjects: [ProjectOverviewItem] {
        sidebarViewModel.allProjectItems.filter { $0.parentProjectId == nil }
    }

    private var title: String {
        switch request {
        case let .organization(parentID):
            parentID == nil ? L10n.newOrganization : L10n.newDepartment
        case .contact:
            L10n.customerIntelligenceNewPerson
        case .project:
            L10n.newProject
        case .topic:
            L10n.customerIntelligenceNewTopic
        }
    }

    private var canSubmit: Bool {
        switch request {
        case .organization:
            name.nilIfBlank != nil
        case .contact:
            name.nilIfBlank != nil || email.nilIfBlank != nil
        case .project:
            name.nilIfBlank != nil && selectedOrganizationID != nil
        case .topic:
            name.nilIfBlank != nil && details.nilIfBlank != nil && selectedOrganizationID != nil
        }
    }

    private var sheetHeight: Double {
        switch request {
        case .organization: 400
        case .contact: 400
        case .project: 560
        case .topic: 440
        }
    }

    private func submit() async {
        isSaving = true
        defer { isSaving = false }
        let didCreate: Bool
        switch request {
        case let .organization(parentID):
            didCreate = await onCreateOrganization(name, parentID, details)
        case .contact:
            didCreate = await onCreateContact(name, email, selectedOrganizationID)
        case .project:
            guard let organizationID = selectedOrganizationID else { return }
            didCreate = await onCreateProject(
                name,
                selectedProjectParentID,
                projectType,
                details,
                organizationID
            )
        case .topic:
            guard let organizationID = selectedOrganizationID else { return }
            didCreate = await onCreateTopic(name, details, organizationID)
        }
        if didCreate {
            dismiss()
        } else {
            errorMessage = L10n.customerIntelligenceSaveFailed
        }
    }
}
