import DahliaRuntimeSupport
import GRDB
import SwiftUI

struct CustomerIntelligenceTopicsView: View {
    let initialTopicID: UUID?
    let reloadToken: Int
    @Binding var showsInspector: Bool
    let onOpenResource: (CustomerIntelligenceWorkspaceData.ResourceLink) -> Void
    let onOpenMeeting: (UUID) -> Void

    @State private var model: CustomerIntelligenceTopicsViewModel
    @State private var selectedTopicID: UUID?
    @State private var editedTopic: ConversationTopicRecord?
    @State private var sortOrder = [
        KeyPathComparator(\ConversationTopicOverview.sortTitle),
    ]
    @ObservedObject private var settings = AppSettings.shared

    init(
        dbQueue: DatabaseQueue,
        vaultID: UUID,
        scope: CustomerIntelligenceScope,
        initialTopicID: UUID?,
        reloadToken: Int,
        showsInspector: Binding<Bool>,
        onOpenResource: @escaping (CustomerIntelligenceWorkspaceData.ResourceLink) -> Void,
        onOpenMeeting: @escaping (UUID) -> Void
    ) {
        self.initialTopicID = initialTopicID
        self.reloadToken = reloadToken
        _showsInspector = showsInspector
        self.onOpenResource = onOpenResource
        self.onOpenMeeting = onOpenMeeting
        _model = State(initialValue: CustomerIntelligenceTopicsViewModel(
            dbQueue: dbQueue,
            vaultID: vaultID,
            scope: scope
        ))
        _selectedTopicID = State(initialValue: initialTopicID)
    }

    var body: some View {
        topicTable
            .navigationTitle(L10n.topics)
            .searchable(text: $model.searchText, prompt: L10n.customerIntelligenceSearchTopics)
            .inspector(isPresented: $showsInspector) {
                topicInspector
                    .inspectorColumnWidth(min: 340, ideal: 420, max: 580)
            }
            .task(id: reloadToken) {
                selectedTopicID = initialTopicID ?? selectedTopicID
                await model.load(selectedID: selectedTopicID)
                reconcileSelection()
            }
            .onChange(of: initialTopicID) { _, id in
                selectedTopicID = id
            }
            .onChange(of: selectedTopicID) { _, id in
                Task { await model.select(id) }
            }
            .sheet(item: $editedTopic) { topic in
                CustomerIntelligenceTopicEditorSheet(topic: topic, model: model)
            }
            .alert(item: $model.pendingDeletion) { pending in
                Alert(
                    title: Text(L10n.deleteTopic),
                    message: Text(L10n.topicDeletionImpact(pending.impact)),
                    primaryButton: .destructive(Text(L10n.delete)) {
                        Task {
                            if await model.confirmDeletion(pending) {
                                selectedTopicID = nil
                            }
                        }
                    },
                    secondaryButton: .cancel()
                )
            }
            .customerIntelligenceErrorAlert(
                title: L10n.customerIntelligenceTopicsError,
                message: $model.errorMessage
            )
    }

    private var topicTable: some View {
        Table(
            model.filteredTopics.sorted(using: sortOrder),
            selection: $selectedTopicID,
            sortOrder: $sortOrder
        ) {
            TableColumn(L10n.customerIntelligenceTopicTitle, value: \.sortTitle) { topic in
                Text(topic.topic.title)
                    .lineLimit(2)
            }
            TableColumn(L10n.customerIntelligenceCurrentState, value: \.sortCurrentState) { topic in
                Text(topic.topic.currentState)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            TableColumn(L10n.customerIntelligenceLastDiscussed, value: \.sortLastDiscussedAt) { topic in
                if let date = topic.lastDiscussedAt {
                    Text(date, format: .dateTime.year().month().day())
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
            .width(min: 110, ideal: 130)
            TableColumn(L10n.meetings, value: \.meetingCount) { topic in
                Text(topic.meetingCount, format: .number)
                    .monospacedDigit()
            }
            .width(70)
            TableColumn(L10n.department, value: \.organizationCount) { topic in
                Text(topic.organizationCount, format: .number)
                    .monospacedDigit()
            }
            .width(70)
        }
        .customerIntelligenceTableStyle()
        .environment(\.defaultMinListRowHeight, tableRowHeight)
        .overlay {
            if model.filteredTopics.isEmpty, !model.isLoading {
                if model.searchText.nilIfBlank != nil {
                    ContentUnavailableView.search
                } else {
                    ContentUnavailableView(
                        L10n.customerIntelligenceNoTopics,
                        systemImage: "text.bubble",
                        description: Text(L10n.customerIntelligenceNoTopicsDescription)
                    )
                }
            } else if model.isLoading, model.topics.isEmpty {
                ProgressView()
            }
        }
    }

    @ViewBuilder
    private var topicInspector: some View {
        if let detail = model.detail {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    CustomerIntelligenceInspectorHeader(
                        title: detail.overview.topic.title,
                        subtitle: nil,
                        systemImage: "text.bubble",
                        badge: nil,
                        onEdit: { editedTopic = detail.overview.topic }
                    )

                    CustomerIntelligenceInspectorSection(title: L10n.customerIntelligenceCurrentState) {
                        Text(detail.overview.topic.currentState)
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

                    if !detail.meetings.isEmpty {
                        CustomerIntelligenceInspectorSection(title: L10n.topicMeetingEvidence) {
                            ForEach(detail.meetings) { evidence in
                                CustomerIntelligenceLinkRow(
                                    title: evidence.meeting.name,
                                    subtitle: evidence.note.nilIfBlank
                                        ?? evidence.meeting.createdAt.formatted(date: .abbreviated, time: .omitted),
                                    systemImage: "calendar",
                                    action: { onOpenMeeting(evidence.meeting.id) }
                                )
                            }
                        }
                    }

                    CustomerIntelligenceDangerSection(
                        title: L10n.deleteTopic,
                        message: L10n.customerIntelligenceDeleteTopicHelp,
                        action: { Task { await model.prepareDeletion(detail.overview.topic) } }
                    )
                }
                .padding()
            }
        } else {
            ContentUnavailableView(
                L10n.customerIntelligenceSelectTopic,
                systemImage: "text.bubble"
            )
        }
    }

    private var tableRowHeight: Double {
        settings.customerIntelligenceTableDensityRawValue == CustomerIntelligenceTableDensity.compact.rawValue
            ? 28 : 44
    }

    private func reconcileSelection() {
        if let selectedTopicID, model.topics.contains(where: { $0.id == selectedTopicID }) {
            return
        }
        selectedTopicID = nil
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

private extension ConversationTopicOverview {
    var sortTitle: String { topic.title }
    var sortCurrentState: String { topic.currentState }
    var sortLastDiscussedAt: Date { lastDiscussedAt ?? .distantPast }
}

private struct CustomerIntelligenceTopicEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let topic: ConversationTopicRecord
    let model: CustomerIntelligenceTopicsViewModel

    @State private var title: String
    @State private var currentState: String

    init(topic: ConversationTopicRecord, model: CustomerIntelligenceTopicsViewModel) {
        self.topic = topic
        self.model = model
        _title = State(initialValue: topic.title)
        _currentState = State(initialValue: topic.currentState)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let errorMessage = model.errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    TextField(L10n.customerIntelligenceTopicTitle, text: $title)
                    TextField(
                        L10n.customerIntelligenceCurrentState,
                        text: $currentState,
                        axis: .vertical
                    )
                    .lineLimit(6 ... 12)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(L10n.customerIntelligenceEditTopic)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.cancel, action: dismiss.callAsFunction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.save) {
                        Task {
                            if await model.save(topic: topic, title: title, currentState: currentState) {
                                dismiss()
                            }
                        }
                    }
                    .disabled(title.nilIfBlank == nil || currentState.nilIfBlank == nil || model.isSaving)
                }
            }
        }
        .frame(minWidth: 540, minHeight: 440)
    }
}
