import SwiftUI

struct CustomerIntelligenceScopePicker: View {
    let scope: CustomerIntelligenceScope
    let roots: [OrganizationWorkspaceNode]
    let onSelect: (CustomerIntelligenceScope) -> Void

    @State private var isPresented = false

    var body: some View {
        Button(
            action: { isPresented = true },
            label: {
                HStack(spacing: 6) {
                    Image(systemName: scope == .all ? "building.2.crop.circle" : "building.2")
                    Text(scopeTitle)
                        .lineLimit(1)
                }
            }
        )
        .buttonStyle(.bordered)
        .help(L10n.customerIntelligenceCustomerScope)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            CustomerIntelligenceScopePopover(
                scope: scope,
                roots: roots,
                onSelect: {
                    onSelect($0)
                    isPresented = false
                }
            )
        }
    }

    private var scopeTitle: String {
        guard let id = scope.organizationID else {
            return L10n.customerIntelligenceAllCustomers
        }
        return roots.first(where: { $0.id == id })?.organization.name ?? L10n.selectOrganization
    }
}

private struct CustomerIntelligenceScopePopover: View {
    let scope: CustomerIntelligenceScope
    let roots: [OrganizationWorkspaceNode]
    let onSelect: (CustomerIntelligenceScope) -> Void

    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            TextField(L10n.customerIntelligenceSearchCustomers, text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding()

            Divider()

            List {
                scopeButton(
                    title: L10n.customerIntelligenceAllCustomers,
                    systemImage: "building.2.crop.circle",
                    value: .all
                )
                ForEach(filteredRoots) { root in
                    scopeButton(
                        title: root.organization.name,
                        systemImage: "building.2",
                        value: .organization(root.id)
                    )
                }
            }
            .listStyle(.inset)
        }
        .frame(minWidth: 320, minHeight: 320)
    }

    private var filteredRoots: [OrganizationWorkspaceNode] {
        guard let query = searchText.nilIfBlank else { return roots }
        return roots.filter { $0.organization.name.localizedStandardContains(query) }
    }

    private func scopeButton(
        title: String,
        systemImage: String,
        value: CustomerIntelligenceScope
    ) -> some View {
        Button {
            onSelect(value)
        } label: {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                if value == scope {
                    Image(systemName: "checkmark")
                        .accessibilityHidden(true)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(value == scope ? .isSelected : [])
    }
}
