import SwiftUI

struct WorkspaceImportView: View {
    let pending: PendingWorkspaceServerAdoption
    let isBusy: Bool
    let onCancel: () -> Void
    let onReload: () async -> Void
    let onCreateOrganization: (String, String, String) async -> (created: Bool, selectableID: UUID?)
    let onLoadOwners: (Int) async -> (items: [CloudOrganizationOwner], hasMore: Bool)
    let onImport: (UUID?, UUID?) async -> Void

    @State private var useExisting = true
    @State private var destinationId: UUID?
    @State private var organizationId: UUID?
    @State private var organizationName = ""
    @State private var isCreating = false
    @State private var organizationSlug = ""
    @State private var ownerId = ""
    @State private var owners: [CloudOrganizationOwner] = []
    @State private var hasMoreOwners = true
    @State private var isLoadingOwners = false

    private var destinations: [CloudWorkspaceRecord] {
        pending.serverWorkspaces.filter { $0.workspaceId != pending.workspace.id && ["admin", "editor"].contains($0.role) }
    }

    var body: some View {
        ZStack {
            Button(action: onCancel) {
                Color.black.opacity(0.16).ignoresSafeArea()
            }
            .buttonStyle(.plain)
            .focusable(false)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.workspaceImportDestination).font(.title2)
                Text(pending.workspace.name).font(.headline)
                Text(L10n.workspaceImportDescription).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Picker(L10n.workspaceImportDestination, selection: $useExisting) {
                    Text(L10n.workspaceImportExisting).tag(true)
                    Text(L10n.workspaceImportNew).tag(false)
                }.pickerStyle(.segmented)
                if useExisting {
                    Picker(L10n.workspaceImportExisting, selection: $destinationId) {
                        Text("—").tag(nil as UUID?)
                        ForEach(destinations) { workspace in
                            Text(workspace.name + " (" + (workspace.role == "admin" ? L10n.workspaceAdmin : L10n.workspaceEditor) + ")")
                                .tag(Optional(workspace.workspaceId))
                        }
                    }
                } else {
                    Picker(L10n.workspaceImportOrganization, selection: $organizationId) {
                        Text("—").tag(nil as UUID?)
                        ForEach(pending.organizations.filter { $0.kind == .team }, id: \.id) { organization in
                            Text(organization.name).tag(UUID(uuidString: organization.id))
                        }
                    }
                    if pending.canCreateOrganizations {
                        TextField(L10n.workspaceImportName, text: $organizationName)
                        TextField("slug", text: $organizationSlug)
                        Picker(L10n.organizationInitialOwner, selection: $ownerId) {
                            Text("—").tag("")
                            ForEach(owners) { owner in
                                Text(owner.name + " (" + owner.email + ")").tag(owner.id)
                            }
                        }
                        Text(L10n.organizationOwnerImportRequirement)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if hasMoreOwners {
                            Button(L10n.organizationLoadOwners) { Task { await loadOwners() } }
                                .buttonStyle(.dahlia())
                                .disabled(isLoadingOwners)
                        }
                        Button(L10n.workspaceImportCreateOrganization) {
                            isCreating = true
                            Task {
                                let result = await onCreateOrganization(organizationName, organizationSlug, ownerId)
                                if result.created {
                                    organizationId = result.selectableID
                                    organizationName = ""
                                    organizationSlug = ""
                                }
                                isCreating = false
                            }
                        }
                        .buttonStyle(.dahlia())
                        .disabled(organizationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || organizationSlug.isEmpty || ownerId
                            .isEmpty || isCreating)
                    }
                }
                HStack {
                    Button(L10n.workspaceImportRefresh) { Task { await onReload() } }
                        .buttonStyle(.dahlia())
                    Spacer()
                    Button(L10n.cancel, action: onCancel)
                        .buttonStyle(.dahlia())
                        .keyboardShortcut(.cancelAction)
                    Button(L10n.workspaceImportStart) {
                        Task { await onImport(useExisting ? destinationId : nil, useExisting ? nil : organizationId) }
                    }
                    .buttonStyle(.dahlia(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(useExisting ? destinationId == nil : organizationId == nil)
                }
                if isBusy || isCreating { ProgressView().controlSize(.small) }
            }
            .padding(24)
            .frame(width: 520)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(.rect(cornerRadius: DahliaDesign.Card.regularCornerRadius))
            .shadow(color: .black.opacity(0.24), radius: 28, y: 12)
        }
        .transition(.identity)
        .disabled(isBusy || isCreating)
        .task {
            destinationId = destinations.first?.workspaceId
            organizationId = pending.organizations.first(where: { $0.kind == .team }).flatMap { UUID(uuidString: $0.id) }
            let teamOrganizationIDs = Set(pending.organizations.filter { $0.kind == .team }.compactMap { UUID(uuidString: $0.id) })
            let hasTeamWorkspace = destinations.contains { teamOrganizationIDs.contains($0.organizationId) }
            useExisting = !destinations.isEmpty && (teamOrganizationIDs.isEmpty || hasTeamWorkspace)
            if pending.canCreateOrganizations { await loadOwners() }
        }
    }

    private func loadOwners() async {
        guard !isLoadingOwners else { return }
        isLoadingOwners = true
        defer { isLoadingOwners = false }
        let page = await onLoadOwners(owners.count)
        guard !Task.isCancelled else { return }
        owners.append(contentsOf: page.items.filter { candidate in !owners.contains(where: { $0.id == candidate.id }) })
        hasMoreOwners = page.hasMore
    }

}
