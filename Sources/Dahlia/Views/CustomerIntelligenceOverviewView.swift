import SwiftUI

struct CustomerIntelligenceOverviewView: View {
    let overview: CustomerIntelligenceWorkspaceData.Overview
    let scope: CustomerIntelligenceScope
    let roots: [OrganizationWorkspaceNode]
    let isLoading: Bool
    let onSelectScope: (CustomerIntelligenceScope) -> Void
    let onOpenSection: (CustomerIntelligenceSection) -> Void
    let onOpenContact: (UUID) -> Void
    let onOpenProject: (UUID) -> Void
    let onOpenTopic: (UUID) -> Void
    let onOpenInsight: (UUID) -> Void
    let onOpenMeetings: () -> Void
    let onOpenMeeting: (UUID) -> Void

    private let metricColumns = [
        GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 12),
    ]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                header
                metrics
                if scope == .all {
                    customers
                } else {
                    customerSections
                }
            }
            .padding()
        }
        .overlay {
            if isLoading, overview == .empty {
                ProgressView()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(scopeTitle)
                .font(.title2)
            Text(scope == .all
                ? L10n.customerIntelligenceOverviewAllDescription
                : L10n.customerIntelligenceOverviewCustomerDescription)
                .foregroundStyle(DahliaDesign.secondaryTextColor)
        }
    }

    private var metrics: some View {
        LazyVGrid(columns: metricColumns, alignment: .leading, spacing: 12) {
            CustomerIntelligenceMetricTile(
                title: L10n.people,
                value: overview.counts.contacts,
                systemImage: "person.2",
                action: { onOpenSection(.contacts) }
            )
            CustomerIntelligenceMetricTile(
                title: L10n.projects,
                value: overview.counts.projects,
                systemImage: "folder",
                action: { onOpenSection(.projects) }
            )
            CustomerIntelligenceMetricTile(
                title: L10n.topics,
                value: overview.counts.topics,
                systemImage: "text.bubble",
                action: { onOpenSection(.topics) }
            )
            CustomerIntelligenceMetricTile(
                title: L10n.meetings,
                value: overview.counts.meetings,
                systemImage: "calendar",
                action: onOpenMeetings
            )
            CustomerIntelligenceMetricTile(
                title: L10n.customerIntelligenceNeedsReview,
                value: overview.counts.unacceptedInsights,
                systemImage: "lightbulb",
                action: { onOpenSection(.insights) }
            )
        }
    }

    private var customers: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.organizations)
                .font(.title3)
            LazyVGrid(
                columns: CustomerIntelligenceCustomerCardLayout.columns,
                alignment: .leading,
                spacing: CustomerIntelligenceCustomerCardLayout.spacing
            ) {
                ForEach(overview.customers) { customer in
                    CustomerIntelligenceCustomerCard(customer: customer) {
                        onSelectScope(.organization(customer.id))
                    }
                }
            }
        }
    }

    private var customerSections: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 16) {
            GridRow {
                overviewGroup(L10n.customerIntelligenceKeyPeople, systemImage: "person.2") {
                    ForEach(overview.keyContacts) { contact in
                        overviewButton(
                            contact.contact.displayName ?? contact.contact.email ?? L10n.unnamedPerson,
                            detail: contact.lastInteractionAt?.formatted(date: .abbreviated, time: .omitted),
                            action: { onOpenContact(contact.id) }
                        )
                    }
                }
                overviewGroup(L10n.customerIntelligenceRecentProjects, systemImage: "folder") {
                    ForEach(overview.recentProjects) { project in
                        overviewButton(
                            project.project.path,
                            detail: project.latestMeetingDate?.formatted(date: .abbreviated, time: .omitted),
                            action: { onOpenProject(project.id) }
                        )
                    }
                }
            }
            GridRow {
                overviewGroup(L10n.customerIntelligenceRecentTopics, systemImage: "text.bubble") {
                    ForEach(overview.recentTopics) { topic in
                        overviewButton(
                            topic.topic.title,
                            detail: topic.lastDiscussedAt?.formatted(date: .abbreviated, time: .omitted),
                            action: { onOpenTopic(topic.id) }
                        )
                    }
                }
                overviewGroup(L10n.customerIntelligenceRecentMeetings, systemImage: "calendar") {
                    ForEach(overview.recentMeetings, id: \.id) { meeting in
                        overviewButton(
                            meeting.name,
                            detail: meeting.effectiveRecordingStartedAt.formatted(date: .abbreviated, time: .omitted),
                            action: { onOpenMeeting(meeting.id) }
                        )
                    }
                }
            }
            if !overview.pendingInsights.isEmpty {
                GridRow {
                    overviewGroup(L10n.customerIntelligenceNeedsReview, systemImage: "lightbulb") {
                        ForEach(overview.pendingInsights) { insight in
                            overviewButton(
                                insight.insight.content,
                                detail: insight.relatedTitles.joined(separator: " · "),
                                action: { onOpenInsight(insight.id) }
                            )
                        }
                    }
                    Color.clear
                }
            }
        }
    }

    private func overviewGroup(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
        } label: {
            Label(title, systemImage: systemImage)
                .font(.headline)
        }
        .frame(maxWidth: .infinity)
    }

    private func overviewButton(
        _ title: String,
        detail: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(2)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.body)
                        .foregroundStyle(DahliaDesign.secondaryTextColor)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 7)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var scopeTitle: String {
        guard let id = scope.organizationID else {
            return L10n.customerIntelligenceAllCustomers
        }
        return roots.first(where: { $0.id == id })?.organization.name
            ?? L10n.customerIntelligenceOverview
    }
}
