import SwiftUI

struct OrganizationDomainAdditionSheet: View {
    @Environment(\.dismiss) private var dismiss

    let organizationName: String
    let onAdd: (String) async -> Bool

    @State private var domainName = ""
    @State private var isSaving = false

    var body: some View {
        VStack(spacing: 0) {
            DahliaSheetHeader(title: L10n.addOrganizationDomain)

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

            DahliaSheetActionBar {
                Button(L10n.cancel, action: dismiss.callAsFunction)
                    .keyboardShortcut(.cancelAction)
                Button(L10n.add) {
                    Task { await addDomain() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(domainName.nilIfBlank == nil || isSaving)
            }
        }
        .frame(minWidth: 460, minHeight: 240)
        .dahliaSimpleWindowStyle()
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
