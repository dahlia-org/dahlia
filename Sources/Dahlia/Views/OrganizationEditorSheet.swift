import SwiftUI

struct OrganizationEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let organization: OrganizationWorkspaceNode
    let parentCandidates: [OrganizationRecord]
    let onSave: (String, UUID?, String) async -> Bool

    @State private var name: String
    @State private var parentID: UUID?
    @State private var description: String
    @State private var isSaving = false

    init(
        organization: OrganizationWorkspaceNode,
        parentCandidates: [OrganizationRecord],
        onSave: @escaping (String, UUID?, String) async -> Bool
    ) {
        self.organization = organization
        self.parentCandidates = parentCandidates
        self.onSave = onSave
        _name = State(initialValue: organization.organization.name)
        _parentID = State(initialValue: organization.organization.parentOrganizationId)
        _description = State(initialValue: organization.organization.description)
    }

    var body: some View {
        VStack(spacing: 0) {
            DahliaSheetHeader(title: title)

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
                    TextField(L10n.organizationDescription, text: $description, axis: .vertical)
                        .lineLimit(4 ... 8)
                }
            }
            .formStyle(.grouped)

            DahliaSheetActionBar {
                Button(L10n.cancel, action: dismiss.callAsFunction)
                    .keyboardShortcut(.cancelAction)
                Button(L10n.save) {
                    Task { await save() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!hasChanges || name.nilIfBlank == nil || isSaving)
            }
        }
        .frame(minWidth: 520, minHeight: 300)
        .dahliaSimpleWindowStyle()
    }

    private var title: String {
        organization.organization.nodeKind == .organization
            ? L10n.customerIntelligenceEditOrganization
            : L10n.customerIntelligenceEditDepartment
    }

    private var hasChanges: Bool {
        name != organization.organization.name
            || parentID != organization.organization.parentOrganizationId
            || description != organization.organization.description
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        if await onSave(name, parentID, description) {
            dismiss()
        }
    }
}
