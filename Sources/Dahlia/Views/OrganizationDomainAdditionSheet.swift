import SwiftUI

struct OrganizationDomainAdditionSheet: View {
    @Environment(\.dismiss) private var dismiss

    let organizationName: String
    let onAdd: (String) async -> Bool

    @State private var domainName = ""
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.organizationDomain, text: $domainName)
                        .textContentType(.URL)
                        .onSubmit {
                            Task { await addDomain() }
                        }
                } header: {
                    Text(organizationName)
                } footer: {
                    Text(L10n.organizationDomainHelp)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(L10n.addOrganizationDomain)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.cancel, action: dismiss.callAsFunction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.add) {
                        Task { await addDomain() }
                    }
                    .disabled(domainName.nilIfBlank == nil || isSaving)
                }
            }
        }
        .frame(minWidth: 460, minHeight: 240)
    }

    private func addDomain() async {
        guard !isSaving, domainName.nilIfBlank != nil else { return }
        isSaving = true
        defer { isSaving = false }
        if await onAdd(domainName) {
            dismiss()
        }
    }
}
