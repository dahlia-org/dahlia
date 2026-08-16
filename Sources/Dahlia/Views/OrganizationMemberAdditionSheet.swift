import SwiftUI

struct OrganizationMemberAdditionSheet: View {
    @Environment(\.dismiss) private var dismiss

    let model: OrganizationWorkspaceViewModel

    @State private var selectedContactID: UUID?
    @State private var role = ""
    @State private var isSaving = false

    var body: some View {
        VStack(spacing: 0) {
            DahliaSheetHeader(title: L10n.customerIntelligenceAddPerson)

            Form {
                Section {
                    if availableContacts.isEmpty {
                        Text(L10n.customerIntelligenceNoPeopleToAdd)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker(L10n.person, selection: $selectedContactID) {
                            Text(L10n.select).tag(UUID?.none)
                            ForEach(availableContacts) { contact in
                                Text(contact.displayName ?? contact.email ?? L10n.unnamedPerson)
                                    .tag(Optional(contact.id))
                            }
                        }
                        TextField(L10n.role, text: $role)
                        Button(L10n.add) {
                            Task { await add() }
                        }
                        .disabled(selectedContactID == nil || isSaving)
                    }
                } header: {
                    Text(L10n.customerIntelligenceAddPerson)
                } footer: {
                    Text(L10n.customerIntelligenceManagePeopleHelp)
                }
            }
            .formStyle(.grouped)

            DahliaSheetActionBar {
                Button(L10n.done, action: dismiss.callAsFunction)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(minWidth: 540, minHeight: 380)
        .dahliaSimpleWindowStyle()
    }

    private var availableContacts: [ContactRecord] {
        let memberIDs = Set(model.selectedDetail?.members.map(\.id) ?? [])
        return model.contacts.filter { !memberIDs.contains($0.id) }
    }

    private func add() async {
        guard let selectedContactID else { return }
        isSaving = true
        defer { isSaving = false }
        if await model.addMember(contactID: selectedContactID, role: role) {
            self.selectedContactID = nil
            role = ""
        }
    }
}
