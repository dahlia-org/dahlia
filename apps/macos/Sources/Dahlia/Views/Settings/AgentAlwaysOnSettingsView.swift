import SwiftUI

/// The Always-on tab: the inbox and request field, the switch, guidance and work settings, the Sources intake reads,
/// and the events it recorded.
struct AgentAlwaysOnSettingsView: View {
    @State private var model: AgentAlwaysOnSettingsModel
    @State private var deleting: AgentSourceRecord?

    init(account: CodexRuntimeProvider) { _model = State(initialValue: AgentAlwaysOnSettingsModel(account: account)) }

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField(L10n.agentBotRequest, text: $model.request, prompt: Text(L10n.agentBotRequestPlaceholder), axis: .vertical)
                    Button(L10n.agentBotRequestSend) { Task { await model.sendRequest() } }
                        .disabled(model.request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if model.items.isEmpty { Text(L10n.agentBotInboxEmpty).foregroundStyle(.secondary) }
                ForEach(model.items) { item in itemRow(item) }
            } header: {
                AgentSectionHeader(title: L10n.agentBotInbox) {
                    Button(L10n.agentBotHomeOpen, systemImage: "bubble.left.and.bubble.right") { Task { await model.openHome() } }
                }
            }
            Section {
                Toggle(L10n.agentAlwaysOnEnabled, isOn: Binding(get: { !model.paused }, set: { on in Task { await model.setEnabled(on) } }))
                Text(L10n.agentAlwaysOnHelp).foregroundStyle(.secondary)
            } header: {
                AgentSectionHeader(title: L10n.agentAlwaysOnStatus) { EmptyView() }
            }
            Section {
                if model.servers.isEmpty { Text(L10n.agentAlwaysOnNoServers).foregroundStyle(.secondary) }
                if model.sources.isEmpty { Text(L10n.agentAlwaysOnSourcesEmpty).foregroundStyle(.secondary) }
                ForEach(model.sources) { source in sourceRow(source) }
                if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            } header: {
                AgentSectionHeader(title: L10n.agentAlwaysOnSources) {
                    Button(L10n.add, systemImage: "plus") { model.edit(nil) }
                        .disabled(model.servers.isEmpty || model.draft != nil)
                }
            }
            Section {
                TextField(L10n.agentBotGuidance, text: $model.guidance, prompt: Text(L10n.agentBotGuidancePlaceholder), axis: .vertical)
                    .lineLimit(4 ... 12)
                HStack {
                    Text(L10n.agentBotGuidanceHelp).font(.dahliaSecondary).foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.save) { model.saveGuidance() }
                }
            } header: {
                AgentSectionHeader(title: L10n.agentBotGuidance) { EmptyView() }
            }
            Section {
                Text(L10n.agentBotWorkHelp).foregroundStyle(.secondary)
                ForEach(model.servers, id: \.self) { server in
                    Toggle(server, isOn: Binding(get: { model.isWorkServerAllowed(server) }, set: { model.setWorkServer(server, allowed: $0) }))
                        .toggleStyle(.checkbox)
                }
                Toggle(L10n.agentBotWebSearch, isOn: Binding(get: { model.webSearch }, set: { model.setWebSearch($0) }))
                Text(L10n.agentBotWebSearchHelp).font(.dahliaSecondary).foregroundStyle(.secondary)
            } header: {
                AgentSectionHeader(title: L10n.agentBotWork) { EmptyView() }
            }
            if model.draft != nil { editor }
            Section {
                if model.events.isEmpty { Text(L10n.agentAlwaysOnEventsEmpty).foregroundStyle(.secondary) }
                ForEach(model.events) { event in eventRow(event) }
            } header: {
                AgentSectionHeader(title: L10n.agentAlwaysOnEvents) { EmptyView() }
            }
        }
        .formStyle(.grouped).toggleStyle(.switch).font(.dahliaBody).disabled(model.isBusy)
        .task {
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .confirmationDialog(L10n.delete, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            if let source = deleting {
                Button(L10n.delete, role: .destructive) {
                    Task { await model.delete(source) }
                    deleting = nil
                }
            }
        }
    }

    private func itemRow(_ item: AgentItemRecord) -> some View {
        let options = (try? JSONDecoder().decode([String].self, from: Data(item.options.utf8))) ?? []
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(Self.kindLabel(item.kind)).font(.dahliaSecondary).foregroundStyle(.secondary)
                Text(item.title).font(.dahliaHeadline)
                Spacer()
                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.dahliaSecondary).foregroundStyle(.secondary)
            }
            if !item.body.isEmpty { Text(item.body).textSelection(.enabled) }
            HStack {
                switch item.kind {
                case "question":
                    ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                        Button(index == item.recommended ? "\(option) (\(L10n.agentBotRecommended))" : option) {
                            Task { await model.answer(item, with: option) }
                        }
                    }
                    TextField(L10n.agentBotAnswer, text: Binding(get: { model.answers[item.id] ?? "" }, set: { model.answers[item.id] = $0 }))
                    Button(L10n.agentBotAnswerSend) { Task { await model.answer(item, with: model.answers[item.id] ?? "") } }
                        .disabled((model.answers[item.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button(L10n.agentBotDismiss) { Task { await model.dismiss(item) } }
                case "suggestion":
                    Spacer()
                    Button(L10n.agentBotAccept) { Task { await model.answer(item, with: L10n.agentBotAccepted) } }
                    Button(L10n.agentBotDismiss) { Task { await model.dismiss(item) } }
                default:
                    Spacer()
                    Button(L10n.agentBotSeen) { Task { await model.dismiss(item) } }
                }
                if let thread = item.taskID.flatMap({ model.taskThreads[$0] }) {
                    Button(L10n.agentBotOpenTask) { NotificationCenter.default.post(name: AgentLearningSettings.openThread, object: thread) }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private static func kindLabel(_ kind: String) -> String {
        switch kind {
        case "question": L10n.agentBotKindQuestion
        case "suggestion": L10n.agentBotKindSuggestion
        case "approval": L10n.agentBotKindApproval
        default: L10n.agentBotKindReport
        }
    }

    private func sourceRow(_ source: AgentSourceRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(source.name).font(.dahliaHeadline)
                Spacer()
                Toggle(
                    L10n.agentAlwaysOnEnabled,
                    isOn: Binding(get: { source.enabled }, set: { on in Task { await model.setEnabled(source, enabled: on) } })
                )
                .labelsHidden()
                Button(L10n.edit) { model.edit(source) }.disabled(model.draft != nil)
                Button(L10n.delete, role: .destructive) { deleting = source }
            }
            Text("\(source.server) · \(L10n.agentAlwaysOnIntervalMinutes(source.intervalMinutes)) · \(Self.sieveLabel(source.sieve))")
                .font(.dahliaSecondary).foregroundStyle(.secondary)
            Text(source.instructions).textSelection(.enabled)
            Text(source.lastIntakeAt.map { L10n.agentAlwaysOnLastIntake($0.formatted(date: .abbreviated, time: .shortened)) }
                ?? L10n.agentAlwaysOnNeverRead)
                .font(.dahliaSecondary).foregroundStyle(.secondary)
            if source.gapDetectedAt != nil {
                HStack {
                    Label(L10n.agentAlwaysOnGap, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Spacer()
                    Button(L10n.agentAlwaysOnGapDismiss) { Task { await model.clearGap(source) } }
                }
            } else {
                Text(L10n.agentAlwaysOnUnchecked).font(.dahliaSecondary).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var editor: some View {
        let draft = Binding(get: { model.draft ?? .init() }, set: { model.draft = $0 })
        return Section {
            TextField(L10n.name, text: draft.name)
            if let existing = model.draft, existing.id != nil {
                LabeledContent(L10n.agentAlwaysOnServer, value: existing.server)
                Text(L10n.agentAlwaysOnFixedServer).foregroundStyle(.secondary)
            } else {
                Picker(L10n.agentAlwaysOnServer, selection: draft.server) {
                    ForEach(model.servers, id: \.self) { Text($0).font(.dahliaBody).tag($0) }
                }
            }
            TextField(
                L10n.agentAlwaysOnInstructions,
                text: draft.instructions,
                prompt: Text(L10n.agentAlwaysOnInstructionsPlaceholder),
                axis: .vertical
            )
            Picker(L10n.agentAlwaysOnInterval, selection: draft.intervalMinutes) {
                ForEach(AgentAlwaysOnSettingsModel.intervals, id: \.self) {
                    Text(L10n.agentAlwaysOnIntervalMinutes($0)).font(.dahliaBody).tag($0)
                }
            }
            Picker(L10n.agentAlwaysOnSieve, selection: draft.sieve) {
                ForEach(["explicit", "candidate", "ignore"], id: \.self) { Text(Self.sieveLabel($0)).font(.dahliaBody).tag($0) }
            }
            TextField(L10n.agentAlwaysOnAllowedSenders, text: draft.allowedSenders, prompt: Text(L10n.agentAlwaysOnAllowedSendersPlaceholder))
            HStack {
                Spacer()
                Button(L10n.cancel) {
                    model.draft = nil
                    model.error = nil
                }
                Button(L10n.save) { Task { await model.saveDraft() } }.keyboardShortcut(.defaultAction)
            }
        } header: {
            AgentSectionHeader(title: L10n.agentAlwaysOnEditSource) { EmptyView() }
        }
    }

    private func eventRow(_ event: AgentEventRecord) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text([event.sender, event.subject].compactMap(\.self).joined(separator: " · ").nilIfBlank ?? event.externalID ?? "")
                    .lineLimit(1)
                if !event.excerpt.isEmpty {
                    Text(event.excerpt).font(.dahliaSecondary).foregroundStyle(.secondary).lineLimit(2)
                }
                Text("\((event.occurredAt ?? event.createdAt).formatted(date: .abbreviated, time: .shortened)) · \(Self.statusLabel(event.status))")
                    .font(.dahliaSecondary).foregroundStyle(.secondary)
            }
            Spacer()
            // Only http(s) links are stored; see `AgentInboxService.items(from:)`.
            if let link = event.url.flatMap(URL.init(string:)) { Link(L10n.open, destination: link) }
        }
    }

    private static func sieveLabel(_ sieve: String) -> String {
        switch sieve {
        case "candidate": L10n.agentAlwaysOnSieveCandidate
        case "ignore": L10n.agentAlwaysOnSieveIgnore
        default: L10n.agentAlwaysOnSieveExplicit
        }
    }

    private static func statusLabel(_ status: String) -> String {
        switch status {
        case "ignored": L10n.agentAlwaysOnEventIgnored
        case "assigned": L10n.agentAlwaysOnEventAssigned
        case "delivered": L10n.agentAlwaysOnEventDelivered
        case "processed": L10n.agentAlwaysOnEventProcessed
        default: L10n.agentAlwaysOnEventUnassigned
        }
    }
}
