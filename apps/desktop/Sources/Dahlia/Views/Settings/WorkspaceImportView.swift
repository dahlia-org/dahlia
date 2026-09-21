import DahliaRuntimeSupport
import SwiftUI

struct WorkspaceImportView: View {
    let pending: PendingWorkspaceServerAdoption
    let isBusy: Bool
    let onCancel: () -> Void
    let onReload: () async -> Void
    let onImport: (UUID?, UUID?, String?) async -> Void

    @State private var useExisting = true
    @State private var destinationId: UUID?
    @State private var organizationId: UUID?
    @State private var workspaceName = ""

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
                        Text(L10n.workspaceImportSelectWorkspace).tag(nil as UUID?)
                        ForEach(destinations) { workspace in
                            Text(destinationLabel(for: workspace))
                                .tag(Optional(workspace.workspaceId))
                        }
                    }
                } else {
                    Picker(L10n.workspaceImportOrganization, selection: $organizationId) {
                        Text(L10n.workspaceImportSelectOrganization).tag(nil as UUID?)
                        ForEach(pending.organizations, id: \.id) { organization in
                            Text(organization.name).tag(UUID(uuidString: organization.id))
                        }
                    }
                    LabeledContent(L10n.workspaceName) {
                        TextField(L10n.workspaceName, text: $workspaceName)
                            .labelsHidden()
                    }
                }
                HStack {
                    Button(L10n.workspaceImportRefresh) { Task { await onReload() } }
                        .buttonStyle(.dahlia())
                    Spacer()
                    Button(L10n.cancel, action: onCancel)
                        .buttonStyle(.dahlia())
                        .keyboardShortcut(.cancelAction)
                    Button(L10n.workspaceImportStart, action: startImport)
                        .buttonStyle(.dahlia(.primary))
                        .keyboardShortcut(.defaultAction)
                        .disabled(useExisting ? destinationId == nil : !canImportToNewWorkspace)
                }
                if isBusy { ProgressView().controlSize(.small) }
            }
            .padding(24)
            .frame(width: 520)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(.rect(cornerRadius: DahliaDesign.Card.regularCornerRadius))
            .shadow(color: .black.opacity(0.24), radius: 28, y: 12)
        }
        .transition(.identity)
        .disabled(isBusy)
        .task {
            workspaceName = pending.workspace.name
            destinationId = destinations.first?.workspaceId
            let teamOrganizations = pending.organizations
            let initialOrganizationID = teamOrganizations.first.flatMap { UUID(uuidString: $0.id) }
            let teamOrganizationIDs = Set(teamOrganizations.compactMap { UUID(uuidString: $0.id) })
            let hasTeamWorkspace = destinations.contains { teamOrganizationIDs.contains($0.organizationId) }
            let requiresOrganizationSelection = !teamOrganizationIDs.isEmpty && !hasTeamWorkspace
            organizationId = requiresOrganizationSelection ? nil : initialOrganizationID
            useExisting = !destinations.isEmpty && !requiresOrganizationSelection
        }
    }

    private var canImportToNewWorkspace: Bool {
        organizationId != nil && !workspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func startImport() {
        Task {
            if useExisting {
                await onImport(destinationId, nil, nil)
            } else {
                await onImport(nil, organizationId, workspaceName)
            }
        }
    }

    private func destinationLabel(for workspace: CloudWorkspaceRecord) -> String {
        let role = workspace.role == "admin" ? L10n.workspaceAdmin : L10n.workspaceEditor
        let organization = pending.organizations.first(where: {
            UUID(uuidString: $0.id) == workspace.organizationId
        })
        let organizationName = organization?.name ?? TypeID.encode(workspace.organizationId, as: .organization)
        return organizationName + " / " + workspace.name + " (" + role + ")"
    }
}
