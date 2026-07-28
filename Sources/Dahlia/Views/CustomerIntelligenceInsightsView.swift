import DahliaRuntimeSupport
import GRDB
import SwiftUI

struct CustomerIntelligenceInsightsView: View {
    let initialInsightID: UUID?
    let reloadToken: Int
    @Binding var showsInspector: Bool
    let onSelectInsight: (UUID?) -> Void
    let onOpenResource: (CustomerIntelligenceWorkspaceData.ResourceLink) -> Void

    @State private var model: CustomerIntelligenceInsightsViewModel
    @State private var selectedInsightID: UUID?
    @State private var sortOrder = [
        KeyPathComparator(\CustomerIntelligenceWorkspaceData.InsightSummary.insight.content),
    ]
    @ObservedObject private var settings = AppSettings.shared

    init(
        dbQueue: DatabaseQueue,
        vaultID: UUID,
        scope: CustomerIntelligenceScope,
        initialInsightID: UUID?,
        reloadToken: Int,
        showsInspector: Binding<Bool>,
        onSelectInsight: @escaping (UUID?) -> Void,
        onOpenResource: @escaping (CustomerIntelligenceWorkspaceData.ResourceLink) -> Void
    ) {
        self.initialInsightID = initialInsightID
        self.reloadToken = reloadToken
        _showsInspector = showsInspector
        self.onSelectInsight = onSelectInsight
        self.onOpenResource = onOpenResource
        _model = State(initialValue: CustomerIntelligenceInsightsViewModel(
            dbQueue: dbQueue,
            vaultID: vaultID,
            scope: scope
        ))
        _selectedInsightID = State(initialValue: initialInsightID)
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            insightTable
        }
        .navigationTitle(L10n.customerIntelligenceInsights)
        .searchable(text: $model.searchText, prompt: L10n.customerIntelligenceSearchInsights)
        .inspector(isPresented: $showsInspector) {
            insightInspector
                .inspectorColumnWidth(min: 340, ideal: 420, max: 580)
        }
        .task(id: reloadToken) {
            selectedInsightID = initialInsightID ?? selectedInsightID
            await model.load(selectedID: selectedInsightID)
            reconcileSelection()
        }
        .onChange(of: initialInsightID) { _, id in
            selectedInsightID = id
        }
        .onChange(of: selectedInsightID) { _, id in
            onSelectInsight(id)
            Task { await model.select(id) }
        }
        .customerIntelligenceErrorAlert(
            title: L10n.customerIntelligenceInsightsError,
            message: $model.errorMessage
        )
    }

    private var filterBar: some View {
        Picker(L10n.status, selection: $model.isAccepted) {
            Text(L10n.customerIntelligenceNeedsReview).tag(Optional(false))
            Text(L10n.customerIntelligenceAllStatuses).tag(Bool?.none)
            Text(L10n.customerIntelligenceAccepted).tag(Optional(true))
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 420)
        .padding()
    }

    private var insightTable: some View {
        Table(
            model.filteredInsights.sorted(using: sortOrder),
            selection: $selectedInsightID,
            sortOrder: $sortOrder
        ) {
            TableColumn(L10n.customerIntelligenceInsightSummary, value: \.insight.content) { summary in
                Text(summary.insight.content)
                    .lineLimit(2)
            }
            TableColumn(L10n.customerIntelligenceRelatedResources, value: \.sortRelatedTitles) { summary in
                Text(summary.relatedTitles.joined(separator: ", "))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            TableColumn(L10n.customerIntelligenceUpdatedAt, value: \.insight.updatedAt) { summary in
                Text(summary.insight.updatedAt, format: .dateTime.year().month().day())
            }
            .width(min: 110, ideal: 130)
            TableColumn(L10n.status, value: \.sortAcceptance) { summary in
                Text(acceptanceTitle(summary.insight.isAccepted))
                    .foregroundStyle(summary.insight.isAccepted ? Color.secondary : Color.orange)
            }
            .width(min: 90, ideal: 110)
        }
        .customerIntelligenceTableStyle()
        .environment(\.defaultMinListRowHeight, tableRowHeight)
        .overlay {
            if model.filteredInsights.isEmpty, !model.isLoading {
                if model.searchText.nilIfBlank != nil {
                    ContentUnavailableView.search
                } else {
                    ContentUnavailableView(
                        L10n.customerIntelligenceNoInsights,
                        systemImage: "lightbulb",
                        description: Text(L10n.customerIntelligenceNoInsightsDescription)
                    )
                }
            } else if model.isLoading, model.insights.isEmpty {
                ProgressView()
            }
        }
    }

    @ViewBuilder
    private var insightInspector: some View {
        if let detail = model.detail {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    CustomerIntelligenceInspectorHeader(
                        title: acceptanceTitle(detail.summary.insight.isAccepted),
                        subtitle: detail.summary.insight.updatedAt.formatted(
                            date: .abbreviated,
                            time: .shortened
                        ),
                        systemImage: "lightbulb",
                        badge: detail.summary.insight.isAccepted
                            ? nil
                            : L10n.customerIntelligenceNeedsReview,
                        onEdit: nil
                    )

                    CustomerIntelligenceInspectorSection(title: L10n.customerIntelligenceInsightContent) {
                        Text(detail.summary.insight.content)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if !detail.references.isEmpty {
                        CustomerIntelligenceInspectorSection(title: L10n.customerIntelligenceRelatedResources) {
                            ForEach(detail.references) { link in
                                CustomerIntelligenceLinkRow(
                                    title: link.title,
                                    subtitle: link.role,
                                    systemImage: icon(for: link.kind),
                                    action: { onOpenResource(link) }
                                )
                            }
                        }
                    }

                    if detail.summary.insight.isAccepted {
                        Button(L10n.customerIntelligenceMarkNeedsReview) {
                            Task { await model.setAccepted(false) }
                        }
                        .disabled(model.isSaving)
                    } else {
                        Button(L10n.customerIntelligenceAccept, systemImage: "checkmark") {
                            Task { await model.setAccepted(true) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isSaving)
                    }
                }
                .padding()
            }
        } else {
            ContentUnavailableView(
                L10n.customerIntelligenceSelectInsight,
                systemImage: "lightbulb"
            )
        }
    }

    private var tableRowHeight: Double {
        settings.customerIntelligenceTableDensityRawValue == CustomerIntelligenceTableDensity.compact.rawValue
            ? 28 : 44
    }

    private func reconcileSelection() {
        if let selectedInsightID, model.insights.contains(where: { $0.id == selectedInsightID }) {
            return
        }
        selectedInsightID = nil
    }

    private func acceptanceTitle(_ isAccepted: Bool) -> String {
        isAccepted ? L10n.customerIntelligenceAccepted : L10n.customerIntelligenceNeedsReview
    }

    private func icon(for kind: CustomerIntelligenceResourceKind) -> String {
        switch kind {
        case .organization: "building.2"
        case .contact: "person.crop.circle"
        case .project: "folder"
        case .meeting: "calendar"
        case .topic: "text.bubble"
        }
    }
}
