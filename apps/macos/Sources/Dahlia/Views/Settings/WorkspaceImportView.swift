import DahliaRuntimeSupport
import SwiftUI

struct WorkspaceImportView: View {
    let pending: PendingWorkspaceServerAdoption
    let isBusy: Bool
    let step: LocalWorkspaceImport.Step?
    let onCancel: () -> Void
    let onReload: () async -> Void
    let onImport: (UUID?, UUID?, String?, Bool) async -> Void

    @State private var reconnectExisting = false
    @State private var useExisting = true
    @State private var destinationId: UUID?
    @State private var organizationId: UUID?
    @State private var workspaceName = ""

    private var destinations: [CloudWorkspaceRecord] {
        pending.serverWorkspaces.filter { ["admin", "editor"].contains($0.role) }
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
                Text(L10n.workspaceImportDestination).font(.dahliaTitle2)
                Text(pending.workspace.name).font(.dahliaHeadline)
                Text(L10n.documentMigrationPrivate).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(L10n.workspaceImportDescription).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Picker(L10n.workspaceImportDestination, selection: $useExisting) {
                    Text(L10n.workspaceImportExisting).font(.dahliaBody).tag(true)
                    Text(L10n.workspaceImportNew).font(.dahliaBody).tag(false)
                }.pickerStyle(.segmented)
                if useExisting {
                    Picker(L10n.workspaceImportExisting, selection: $destinationId) {
                        Text(L10n.workspaceImportSelectWorkspace).font(.dahliaBody).tag(nil as UUID?)
                        ForEach(destinations) { workspace in
                            Text(destinationLabel(for: workspace))
                                .font(.dahliaBody)
                                .tag(Optional(workspace.workspaceId))
                        }
                    }
                    if let destination = destinations.first(where: { $0.workspaceId == destinationId }),
                       destination.workspaceId == pending.workspace.id {
                        Text(L10n.workspaceImportSameIdentity(local: pending.workspace.name, server: destination.name))
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Toggle(L10n.workspaceImportReconnect, isOn: $reconnectExisting)
                        .toggleStyle(.checkbox)
                    if reconnectExisting {
                        Text(L10n.workspaceImportReconnectDescription)
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Picker(L10n.workspaceImportOrganization, selection: $organizationId) {
                        Text(L10n.workspaceImportSelectOrganization).font(.dahliaBody).tag(nil as UUID?)
                        ForEach(pending.organizations, id: \.id) { organization in
                            Text(organization.name).font(.dahliaBody).tag(UUID(uuidString: organization.id))
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
                        .disabled(useExisting ? destinationId == nil || (destinationId == pending.workspace.id && !reconnectExisting) :
                            !canImportToNewWorkspace)
                }
                if isBusy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        if let step { Text(step.label).foregroundStyle(.secondary) }
                    }
                }
            }
            .padding(24)
            .frame(width: 520)
            .dahliaModalSurface()
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
                await onImport(destinationId, nil, nil, reconnectExisting)
            } else {
                await onImport(nil, organizationId, workspaceName, false)
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
