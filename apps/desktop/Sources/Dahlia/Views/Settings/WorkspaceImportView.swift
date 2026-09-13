import SwiftUI

struct WorkspaceImportView: View {
    let pending: PendingWorkspaceServerAdoption
    let isBusy: Bool
    let onCancel: () -> Void
    let onReload: () async -> Void
    let onCreateOrganization: (String) async -> Void
    let onImport: (UUID?, UUID?) async -> Void

    @State private var useExisting = true
    @State private var destinationId: UUID?
    @State private var organizationId: UUID?
    @State private var organizationName = ""
    @State private var isCreating = false

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
                    HStack {
                        TextField(L10n.workspaceImportName, text: $organizationName)
                        Button(L10n.workspaceImportCreateOrganization) {
                            isCreating = true
                            Task {
                                await onCreateOrganization(organizationName)
                                organizationName = ""
                                isCreating = false
                            }
                        }.disabled(organizationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCreating)
                    }
                }
                HStack {
                    Button(L10n.workspaceImportRefresh) { Task { await onReload() } }
                    Spacer()
                    Button(L10n.cancel, action: onCancel).keyboardShortcut(.cancelAction)
                    Button(L10n.workspaceImportStart) {
                        Task { await onImport(useExisting ? destinationId : nil, useExisting ? nil : organizationId) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(useExisting ? destinationId == nil : organizationId == nil)
                }
                if isBusy || isCreating { ProgressView().controlSize(.small) }
            }
            .padding(24)
            .frame(width: 520)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .disabled(isBusy || isCreating)
        .task {
            destinationId = destinations.first?.workspaceId
            organizationId = pending.organizations.first(where: { $0.kind == .team }).flatMap { UUID(uuidString: $0.id) }
            useExisting = !destinations.isEmpty
        }
    }
}
