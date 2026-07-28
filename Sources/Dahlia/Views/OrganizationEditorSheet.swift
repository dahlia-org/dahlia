import SwiftUI

struct OrganizationEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let organization: OrganizationWorkspaceNode
    let parentCandidates: [OrganizationRecord]
    let onSave: (String, UUID?) async -> Bool

    @State private var name: String
    @State private var parentID: UUID?
    @State private var isSaving = false

    init(
        organization: OrganizationWorkspaceNode,
        parentCandidates: [OrganizationRecord],
        onSave: @escaping (String, UUID?) async -> Bool
    ) {
        self.organization = organization
        self.parentCandidates = parentCandidates
        self.onSave = onSave
        _name = State(initialValue: organization.organization.name)
        _parentID = State(initialValue: organization.organization.parentOrganizationId)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.name, text: $name)
                    Picker(L10n.parentDepartment, selection: $parentID) {
                        if organization.organization.nodeKind == .organization {
                            Text(L10n.vaultRoot).tag(UUID?.none)
                        }
                        ForEach(parentCandidates) { candidate in
                            Text(candidate.name).tag(Optional(candidate.id))
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.cancel, action: dismiss.callAsFunction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.save) {
                        Task { await save() }
                    }
                    .disabled(!hasChanges || name.nilIfBlank == nil || isSaving)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 300)
    }

    private var title: String {
        organization.organization.nodeKind == .organization
            ? L10n.customerIntelligenceEditOrganization
            : L10n.customerIntelligenceEditDepartment
    }

    private var hasChanges: Bool {
        name != organization.organization.name
            || parentID != organization.organization.parentOrganizationId
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        if await onSave(name, parentID) {
            dismiss()
        }
    }
}
