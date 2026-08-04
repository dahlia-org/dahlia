import SwiftUI

struct CustomerIntelligenceSidebar: View {
    @Binding var selection: CustomerIntelligenceSection
    let unacceptedInsightCount: Int

    var body: some View {
        List(selection: $selection) {
            Label(L10n.customerIntelligenceOverview, systemImage: "rectangle.grid.2x2")
                .tag(CustomerIntelligenceSection.overview)
            Label(L10n.organizations, systemImage: "building.2")
                .tag(CustomerIntelligenceSection.organizations)
            Label(L10n.people, systemImage: "person.2")
                .tag(CustomerIntelligenceSection.contacts)
            Label(L10n.projects, systemImage: "folder")
                .tag(CustomerIntelligenceSection.projects)
            Label(L10n.topics, systemImage: "text.bubble")
                .tag(CustomerIntelligenceSection.topics)
            insightLabel
                .tag(CustomerIntelligenceSection.insights)
        }
        .listStyle(.sidebar)
        .navigationTitle(L10n.customerIntelligence)
    }

    private var insightLabel: some View {
        HStack {
            Label(L10n.customerIntelligenceInsights, systemImage: "lightbulb")
            Spacer()
            if unacceptedInsightCount > 0 {
                Text(unacceptedInsightCount, format: .number)
                    .font(.caption)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: .capsule)
                    .accessibilityLabel(L10n.customerIntelligenceNeedsReviewCount(unacceptedInsightCount))
            }
        }
    }
}
