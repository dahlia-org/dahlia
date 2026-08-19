import SwiftUI

struct CustomerIntelligenceSidebar: View {
    @Binding var selection: CustomerIntelligenceSection
    let unacceptedInsightCount: Int
    let canGoBack: Bool
    let canGoForward: Bool
    let onGoBack: () -> Void
    let onGoForward: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            navigationControls
            Divider()
            List(selection: $selection) {
                Label(L10n.customerIntelligenceOverview, systemImage: "rectangle.grid.2x2")
                    .modifier(SidebarNavigationRowModifier(isSelected: selection == .overview))
                    .tag(CustomerIntelligenceSection.overview)
                Label(L10n.organizations, systemImage: "building.2")
                    .modifier(SidebarNavigationRowModifier(isSelected: selection == .organizations))
                    .tag(CustomerIntelligenceSection.organizations)
                Label(L10n.people, systemImage: "person.2")
                    .modifier(SidebarNavigationRowModifier(isSelected: selection == .contacts))
                    .tag(CustomerIntelligenceSection.contacts)
                Label(L10n.projects, systemImage: "folder")
                    .modifier(SidebarNavigationRowModifier(isSelected: selection == .projects))
                    .tag(CustomerIntelligenceSection.projects)
                Label(L10n.topics, systemImage: "text.bubble")
                    .modifier(SidebarNavigationRowModifier(isSelected: selection == .topics))
                    .tag(CustomerIntelligenceSection.topics)
                insightLabel
                    .modifier(SidebarNavigationRowModifier(isSelected: selection == .insights))
                    .tag(CustomerIntelligenceSection.insights)
            }
            .listStyle(.sidebar)
        }
    }

    private var navigationControls: some View {
        DahliaWindowHeader(reservesWindowControls: true) {
            Button(L10n.back, systemImage: "chevron.backward", action: onGoBack)
                .labelStyle(.iconOnly)
                .dahliaFixedSymbol()
                .disabled(!canGoBack)
                .help(L10n.back)
            Button(L10n.forward, systemImage: "chevron.forward", action: onGoForward)
                .labelStyle(.iconOnly)
                .dahliaFixedSymbol()
                .disabled(!canGoForward)
                .help(L10n.forward)
            Spacer()
        }
        .buttonStyle(.borderless)
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
