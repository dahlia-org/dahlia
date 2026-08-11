import SwiftUI

struct CustomerIntelligenceOrganizationsGallery: View {
    let customers: [CustomerIntelligenceWorkspaceData.CustomerCard]
    let isLoading: Bool
    let onOpen: (UUID) -> Void

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: CustomerIntelligenceCustomerCardLayout.columns,
                alignment: .leading,
                spacing: CustomerIntelligenceCustomerCardLayout.spacing
            ) {
                ForEach(customers) { customer in
                    CustomerIntelligenceCustomerCard(customer: customer) {
                        onOpen(customer.id)
                    }
                }
            }
            .padding()
        }
        .navigationTitle(L10n.organizations)
        .overlay {
            if isLoading, customers.isEmpty {
                ProgressView()
            } else if customers.isEmpty {
                ContentUnavailableView(
                    L10n.noOrganizations,
                    systemImage: "building.2",
                    description: Text(L10n.noOrganizationsDescription)
                )
            }
        }
    }
}
