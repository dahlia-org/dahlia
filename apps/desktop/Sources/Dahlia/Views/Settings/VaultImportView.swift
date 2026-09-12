import SwiftUI

struct VaultImportView: View {
    let pending: PendingVaultServerAdoption
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

    private var destinations: [CloudVaultRecord] {
        pending.serverVaults.filter { $0.vaultId != pending.vault.id && ["admin", "editor"].contains($0.role) }
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
                Text(L10n.vaultImportDestination).font(.title2)
                Text(pending.vault.name).font(.headline)
                Text(L10n.vaultImportDescription).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Picker(L10n.vaultImportDestination, selection: $useExisting) {
                    Text(L10n.vaultImportExisting).tag(true)
                    Text(L10n.vaultImportNew).tag(false)
                }.pickerStyle(.segmented)
                if useExisting {
                    Picker(L10n.vaultImportExisting, selection: $destinationId) {
                        Text("—").tag(nil as UUID?)
                        ForEach(destinations) { vault in
                            Text(vault.name + " (" + (vault.role == "admin" ? L10n.vaultAdmin : L10n.vaultEditor) + ")").tag(Optional(vault.vaultId))
                        }
                    }
                } else {
                    Picker(L10n.vaultImportOrganization, selection: $organizationId) {
                        Text("—").tag(nil as UUID?)
                        ForEach(pending.organizations.filter { $0.kind == .team }, id: \.id) { organization in
                            Text(organization.name).tag(UUID(uuidString: organization.id))
                        }
                    }
                    HStack {
                        TextField(L10n.vaultImportName, text: $organizationName)
                        Button(L10n.vaultImportCreateOrganization) {
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
                    Button(L10n.vaultImportRefresh) { Task { await onReload() } }
                    Spacer()
                    Button(L10n.cancel, action: onCancel).keyboardShortcut(.cancelAction)
                    Button(L10n.vaultImportStart) {
                        Task { await onImport(useExisting ? destinationId : nil, useExisting ? nil : organizationId) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(useExisting ? destinationId == nil : organizationId == nil)
                }
                if isBusy { ProgressView().controlSize(.small) }
            }
            .padding(24)
            .frame(width: 520)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .disabled(isBusy)
        .task {
            destinationId = destinations.first?.vaultId
            organizationId = pending.organizations.first(where: { $0.kind == .team }).flatMap { UUID(uuidString: $0.id) }
            useExisting = !destinations.isEmpty
        }
    }
}
