import SwiftUI

/// Super Agent's side panel, beside its thread. Its inbox (what waits for the user, its Tasks, the events intake recorded)
/// comes first; its settings (event sources, `SOUL.md`, starting over) sit apart, behind the header's switch. Its model
/// belongs to the window, which shows the event source editor over everything.
struct DahliaBotPanelView: View {
    enum Tab: CaseIterable {
        case inbox, settings

        var title: String { self == .inbox ? L10n.agentBotInboxTab : L10n.agentBotSettings }
        var systemImage: String { self == .inbox ? "tray" : "gearshape" }
    }

    let model: DahliaBotPanelModel
    @State private var tab = Tab.inbox
    @State private var isConfirmingReset = false

    var body: some View {
        VStack(spacing: 0) {
            // Like the chat's own header: the shown view's name, and icon buttons that switch it.
            DahliaWindowHeader(allowsWindowDragging: false, backgroundColor: .clear) {
                Text(tab.title)
                    .font(.dahliaBody)
                    .foregroundStyle(DahliaDesign.primaryTextColor)
                    .padding(.leading, 8)
                Spacer(minLength: 8)
                ForEach(Tab.allCases, id: \.self) { option in
                    DahliaWindowHeaderIconButton(label: option.title, systemImage: option.systemImage) { tab = option }
                        .foregroundStyle(option == tab ? Color.accentColor : DahliaDesign.secondaryTextColor)
                        .background(
                            option == tab ? DahliaDesign.contentHighlightColor : .clear,
                            in: .rect(cornerRadius: DahliaDesign.Highlight.regularCornerRadius)
                        )
                        .accessibilityAddTraits(option == tab ? .isSelected : [])
                }
            }
            // The header reaches into the title bar, where the Form's background would otherwise cover it, as in the chat.
            .zIndex(1)
            Form {
                if model.paused { pausedSection }
                switch tab {
                case .inbox: activity
                case .settings: settings
                }
            }
            .formStyle(.grouped).toggleStyle(.switch).font(.dahliaBody).disabled(model.isBusy)
        }
        .task {
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .confirmationDialog(L10n.agentBotReset, isPresented: $isConfirmingReset) {
            Button(L10n.agentBotReset) {
                Task {
                    guard let thread = await model.reset() else { return }
                    NotificationCenter.default.post(name: AgentLearningSettings.openThread, object: thread)
                }
            }
        } message: {
            Text(L10n.agentBotResetMessage)
        }
    }

    @ViewBuilder
    private var activity: some View {
        Section {
            if model.items.isEmpty { Text(L10n.agentBotInboxEmpty).foregroundStyle(.secondary) }
            ForEach(model.items) { item in itemRow(item) }
        } header: {
            AgentSectionHeader(title: L10n.agentBotInbox) { EmptyView() }
        }
        Section {
            if model.activeTasks.isEmpty { Text(L10n.agentBotTasksEmpty).foregroundStyle(.secondary) }
            ForEach(model.activeTasks) { task in taskRow(task) }
        } header: {
            AgentSectionHeader(title: L10n.agentBotTasks) { EmptyView() }
        }
        if !model.finishedTasks.isEmpty {
            Section {
                ForEach(model.finishedTasks) { task in taskRow(task) }
                if model.hasMoreFinishedTasks {
                    Button(L10n.loadMore) { Task { await model.loadMoreFinishedTasks() } }
                }
            } header: {
                AgentSectionHeader(title: L10n.agentBotTasksFinished) { EmptyView() }
            }
        }
        Section {
            if model.events.isEmpty { Text(L10n.agentAlwaysOnEventsEmpty).foregroundStyle(.secondary) }
            ForEach(model.events) { event in eventRow(event) }
        } header: {
            AgentSectionHeader(title: L10n.agentAlwaysOnEvents) { EmptyView() }
        }
    }

    @ViewBuilder
    private var settings: some View {
        Section {
            Text(L10n.agentAlwaysOnHelp).foregroundStyle(.secondary)
            if model.servers.isEmpty { Text(L10n.agentAlwaysOnNoServers).foregroundStyle(.secondary) }
            if let error = model.error, model.draft == nil { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        } header: {
            AgentSectionHeader(title: L10n.agentAlwaysOnSources) {
                Button(L10n.add, systemImage: "plus") { model.edit(nil) }
                    .disabled(model.servers.isEmpty)
            }
        }
        // One card per source.
        ForEach(model.sources) { source in
            Section { sourceCard(source) }
        }
        Section {
            Text(L10n.agentBotWorkHelp).foregroundStyle(.secondary)
        } header: {
            AgentSectionHeader(title: L10n.agentBotWork) { EmptyView() }
        }
        soulSection
        Section {
            Text(L10n.agentBotResetMessage).foregroundStyle(.secondary)
            Button(L10n.agentBotReset) { isConfirmingReset = true }
        } header: {
            AgentSectionHeader(title: L10n.agentBotConversation) { EmptyView() }
        }
    }

    /// Only for a bot stopped with the switch earlier versions had: each event source now turns on and off by itself.
    private var pausedSection: some View {
        Section {
            HStack {
                Text(L10n.agentBotPaused)
                Spacer()
                Button(L10n.agentBotResume) { Task { await model.setEnabled(true) } }
            }
        }
    }

    private var soulSection: some View {
        Section {
            if let draft = model.soulDraft {
                TextField(
                    "SOUL.md",
                    text: Binding(get: { draft }, set: { model.soulDraft = $0 }),
                    prompt: Text(L10n.agentBotGuidancePlaceholder),
                    axis: .vertical
                )
                .lineLimit(6 ... 20)
                HStack {
                    Spacer()
                    Button(L10n.cancel) { model.soulDraft = nil }
                    Button(L10n.save) { Task { await model.saveSoul() } }.keyboardShortcut(.defaultAction)
                }
            } else {
                Text(model.soul.nilIfBlank ?? L10n.agentBotSoulEmpty)
                    .foregroundStyle(model.soul.nilIfBlank == nil ? .secondary : .primary)
                    .textSelection(.enabled)
                HStack {
                    Spacer()
                    Button(L10n.agentBotShowInFinder) { Task { await model.showSoulInFinder() } }
                    Button(L10n.edit) { model.editSoul() }
                }
            }
            Text(L10n.agentBotSoulHelp).font(.dahliaSecondary).foregroundStyle(.secondary)
        } header: {
            AgentSectionHeader(title: "SOUL.md") { EmptyView() }
        }
    }

    private func taskRow(_ task: AgentTaskRecord) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title).lineLimit(2)
                Text("\(L10n.agentBotTaskStatus(task.status)) · \(task.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.dahliaSecondary).foregroundStyle(.secondary)
            }
            Spacer()
            if task.status == "active" {
                Button(L10n.agentBotFinishTask) { Task { await model.finish(task) } }
            }
            if let thread = task.threadID {
                Button(L10n.agentBotOpenTask) { NotificationCenter.default.post(name: AgentLearningSettings.openThread, object: thread) }
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

    private func sourceCard(_ source: AgentSourceRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                AgentMCPServiceLogo.image(for: model.services[source.server] ?? source.server)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.name).font(.dahliaHeadline)
                    Text(source.instructions).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 8)
                Toggle(source.name, isOn: Binding(get: { source.enabled }, set: { on in Task { await model.setEnabled(source, enabled: on) } }))
                    .labelsHidden()
            }
            HStack(alignment: .firstTextBaseline) {
                Text([
                    L10n.agentAlwaysOnIntervalMinutes(source.intervalMinutes),
                    Self.sieveLabel(source.sieve),
                    source.lastIntakeAt.map { L10n.agentAlwaysOnLastIntake($0.formatted(date: .abbreviated, time: .shortened)) }
                        ?? L10n.agentAlwaysOnNeverRead,
                ].joined(separator: " · "))
                    .font(.dahliaSecondary).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.edit) { model.edit(source) }
            }
            if source.gapDetectedAt != nil {
                HStack {
                    Label(L10n.agentAlwaysOnGap, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Spacer()
                    Button(L10n.agentAlwaysOnGapDismiss) { Task { await model.clearGap(source) } }
                }
            }
        }
        .padding(.vertical, 4)
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

    static func sieveLabel(_ sieve: String) -> String {
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
