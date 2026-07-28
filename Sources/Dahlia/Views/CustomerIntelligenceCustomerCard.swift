import SwiftUI

struct CustomerIntelligenceCustomerCard: View {
    let customer: CustomerIntelligenceWorkspaceData.CustomerCard
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Label(customer.root.organization.name, systemImage: "building.2")
                    .font(.headline)
                    .lineLimit(2)

                if let description = customer.root.organization.description.nilIfBlank {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 16) {
                    count(customer.organizationCount, title: L10n.organizations, systemImage: "rectangle.3.group")
                    count(customer.contactCount, title: L10n.people, systemImage: "person.2")
                    count(customer.topicCount, title: L10n.topics, systemImage: "text.bubble")
                }
                .foregroundStyle(.secondary)

                if let date = customer.lastInteractionAt {
                    Label {
                        Text(date, format: .relative(presentation: .named))
                    } icon: {
                        Image(systemName: "clock")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                } else {
                    Text(L10n.customerIntelligenceNoRecentInteraction)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            .padding()
            .customerIntelligenceCardSurface()
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint(L10n.customerIntelligenceOpenOrganizationHint)
    }

    private func count(_ value: Int, title: String, systemImage: String) -> some View {
        Label(value.formatted(), systemImage: systemImage)
            .monospacedDigit()
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel(title)
            .accessibilityValue(value.formatted())
    }
}
