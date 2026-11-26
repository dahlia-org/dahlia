import SwiftUI

/// Super Agent's side panel, beside its thread. Its inbox (what waits for the user, its Tasks, the events intake recorded)
/// comes first; its settings (event sources, `SOUL.md`, starting over) sit apart, behind the header's switch. Its model
/// belongs to the window, which shows the event source editor over everything.
struct DahliaBotPanelView: View {
    enum Tab: CaseIterable {
        case inbox, events, settings

        var title: String {
            switch self {
            case .inbox: L10n.agentBotInboxTab
            case .events: L10n.agentAlwaysOnEvents
            case .settings: L10n.agentBotSettings
            }
        }

        var systemImage: String {
            switch self {
            case .inbox: "tray"
            case .events: "clock"
            case .settings: "gearshape"
            }
        }
    }

    let model: DahliaBotPanelModel
    @State private var tab = Tab.inbox
    @State private var isConfirmingReset = false

    var body: some View {
        VStack(spacing: 0) {
            // Tabs like the left sidebar's, leading; the window's side panel toggle sits over the trailing end.
            DahliaWindowHeader(allowsWindowDragging: false, backgroundColor: .clear) {
                IconTabBar(
                    tabs: Tab.allCases,
                    selection: tab,
                    title: \.title,
                    systemImage: \.systemImage,
                    onSelect: { tab = $0 }
                )
                .mainSidebarHelpOverlay(isVisible: true)
                Color.clear
                    .frame(width: DahliaDesign.windowHeaderControlSize, height: DahliaDesign.windowHeaderControlSize)
                    .accessibilityHidden(true)
            }
            // The header reaches into the title bar, where the Form's background would otherwise cover it, as in the chat.
            .zIndex(1)
            Form {
                if model.paused { pausedSection }
                switch tab {
                case .inbox: activity
                case .events: timeline
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
                        .disabled(model.isLoadingFinishedTasks)
                }
            } header: {
                AgentSectionHeader(title: L10n.agentBotTasksFinished) { EmptyView() }
            }
        }
    }

    /// The recorded events, newest first, under one label per day, as the meeting sidebar lists meetings.
    @ViewBuilder
    private var timeline: some View {
        let days = Dictionary(grouping: model.events) { Calendar.current.startOfDay(for: $0.occurredAt) }
        if days.isEmpty {
            Section { Text(L10n.agentAlwaysOnEventsEmpty).foregroundStyle(.secondary) }
        }
        ForEach(days.keys.sorted(by: >), id: \.self) { day in
            Section {
                ForEach(days[day, default: []].sorted { $0.occurredAt > $1.occurredAt }) { event in eventRow(event) }
            } header: {
                Text(MeetingDateGrouping.title(for: day)).font(.dahliaSectionHeader)
            }
        }
    }

    @ViewBuilder
    private var settings: some View {
        // One group, with a row per source.
        Section {
            ForEach(model.sources) { source in sourceCard(source) }
            if model.servers.isEmpty { Text(L10n.agentAlwaysOnNoServers).foregroundStyle(.secondary) }
            if let error = model.error, model.draft == nil { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        } header: {
            HStack {
                Text(L10n.agentAlwaysOnSources).font(.dahliaSectionHeader)
                SettingsInfoButton(help: L10n.agentAlwaysOnHelp)
                Spacer()
                Button(L10n.add, systemImage: "plus") { model.edit(nil) }.font(.dahliaBody)
            }
        }
        Section {
            modelPicker(
                L10n.agentBotIntakeModel, help: L10n.agentBotIntakeModelHelp, fallback: L10n.agentBotModelDefault,
                selection: Binding(get: { model.intakeModel }, set: { model.setIntakeModel($0) }),
                effort: Binding(get: { model.intakeEffort }, set: { model.intakeEffort = $0 })
            )
            modelPicker(
                L10n.agentBotUnattendedModel, help: L10n.agentBotUnattendedModelHelp, fallback: L10n.agentBotModelConversation,
                selection: Binding(get: { model.unattendedModel }, set: { model.setUnattendedModel($0) }),
                effort: Binding(get: { model.unattendedEffort }, set: { model.unattendedEffort = $0 })
            )
        } header: {
            AgentSectionHeader(title: L10n.agentBotModels) { EmptyView() }
        }
        soulSection
        Section {
            Text(L10n.agentBotResetMessage).foregroundStyle(.secondary)
            Button(L10n.agentBotReset) { isConfirmingReset = true }
        } header: {
            AgentSectionHeader(title: L10n.agentBotConversation) { EmptyView() }
        }
    }

    /// A model and its reasoning effort, as one choice on one row. With no model, both follow `fallback` and the effort
    /// is not shown; a saved model or effort no longer listed stays selectable instead of silently changing.
    private func modelPicker(_ title: String, help: String, fallback: String, selection: Binding<String>, effort: Binding<String>)
        -> some View {
        LabeledContent {
            HStack(spacing: 6) {
                Picker(title, selection: selection) {
                    Text(fallback).font(.dahliaBody).tag("")
                    if !selection.wrappedValue.isEmpty, !model.models.contains(where: { $0.model == selection.wrappedValue }) {
                        Text(selection.wrappedValue).font(.dahliaBody).tag(selection.wrappedValue)
                    }
                    ForEach(model.models) { Text($0.displayName).font(.dahliaBody).tag($0.model) }
                }
                .labelsHidden()
                .fixedSize()
                if !selection.wrappedValue.isEmpty {
                    Picker(L10n.agentBotEffort, selection: effort) {
                        ForEach(model.models.reasoningEfforts(for: selection.wrappedValue, keeping: effort.wrappedValue)) { option in
                            Text(option.displayName).font(.dahliaBody).tag(option.reasoningEffort)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help(L10n.agentBotEffort)
                }
            }
        } label: {
            HStack {
                Text(title)
                SettingsInfoButton(help: help)
            }
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
                    L10n.agentBotSoul,
                    text: Binding(get: { draft }, set: { model.soulDraft = $0 }),
                    prompt: Text(L10n.agentBotGuidancePlaceholder),
                    axis: .vertical
                )
                .labelsHidden()
                .multilineTextAlignment(.leading)
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
        } header: {
            HStack {
                Text(L10n.agentBotSoul).font(.dahliaSectionHeader)
                SettingsInfoButton(help: L10n.agentBotSoulHelp)
            }
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
            // The kind and time, with the action that clears the Item at the top right; the title gets the whole width.
            HStack(alignment: .center, spacing: 8) {
                Self.kindBadge(item.kind)
                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.dahliaSecondary).foregroundStyle(.secondary)
                Spacer()
                // Dismissing drops a question or suggestion, so it reads as destructive; a report is only marked seen.
                Button(item.kind == "report" ? L10n.agentBotSeen : L10n.agentBotDismiss) { Task { await model.dismiss(item) } }
                    .buttonStyle(.dahlia(item.kind == "report" ? .secondary : .destructive))
                    .font(.dahliaSecondary)
            }
            Text(item.title).font(.dahliaHeadline).fixedSize(horizontal: false, vertical: true)
            if !item.body.isEmpty { Text(item.body).textSelection(.enabled) }
            if item.kind == "question" {
                // One full-width button per option, so a long option reads in full.
                ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                    Button { Task { await model.answer(item, with: option) } } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(option).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            if index == item.recommended { Text(L10n.agentBotRecommended).font(.dahliaSecondary) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.dahlia(index == item.recommended ? .primary : .secondary))
                }
                HStack {
                    TextField(
                        L10n.agentBotAnswer,
                        text: Binding(get: { model.answers[item.id] ?? "" }, set: { model.answers[item.id] = $0 }),
                        prompt: Text(L10n.agentBotAnswerPlaceholder),
                        axis: .vertical
                    )
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1 ... 4)
                    Button(L10n.agentBotAnswerSend) { Task { await model.answer(item, with: model.answers[item.id] ?? "") } }
                        .disabled((model.answers[item.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            let thread = item.taskID.flatMap { model.taskThreads[$0] }
            if item.kind == "suggestion" || thread != nil {
                HStack {
                    Spacer()
                    if let thread {
                        Button(L10n.agentBotOpenTask) { NotificationCenter.default.post(name: AgentLearningSettings.openThread, object: thread) }
                    }
                    if item.kind == "suggestion" {
                        Button(L10n.agentBotAccept) { Task { await model.answer(item, with: L10n.agentBotAccepted) } }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// The three kinds `item_create` accepts, each with its own symbol and color.
    private static func kindBadge(_ kind: String) -> some View {
        let (title, symbol, tint): (String, String, Color) = switch kind {
        case "question": (L10n.agentBotKindQuestion, "questionmark.circle.fill", .orange)
        case "suggestion": (L10n.agentBotKindSuggestion, "lightbulb.fill", .accentColor)
        default: (L10n.agentBotKindReport, "doc.text.fill", .secondary)
        }
        return HStack(spacing: 3) {
            Image(systemName: symbol).accessibilityHidden(true)
            Text(title)
        }
        .font(.dahliaSecondary)
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tint.opacity(0.12), in: .capsule)
    }

    private func sourceCard(_ source: AgentSourceRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                (source.kind == "calendar" ? Image(systemName: "calendar") : AgentMCPServiceLogo
                    .image(for: model.services[source.server] ?? source.server))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.name).font(.dahliaHeadline)
                    Text(source.kind == "calendar" ? L10n.agentCalendarScheduleHelp : source.instructions).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 8)
                Toggle(source.name, isOn: Binding(get: { source.enabled }, set: { on in Task { await model.setEnabled(source, enabled: on) } }))
                    .labelsHidden()
            }
            HStack(alignment: .firstTextBaseline) {
                Text([
                    source.kind == "calendar" ? L10n.agentCalendarSource : L10n.agentAlwaysOnIntervalMinutes(source.intervalMinutes),
                    L10n.agentAlwaysOnCounts(read: source.lastReadCount, recorded: source.lastRecordedCount),
                    source.lastIntakeAt.map { L10n.agentAlwaysOnLastIntake($0.formatted(date: .abbreviated, time: .shortened)) }
                        ?? L10n.agentAlwaysOnNeverRead,
                ].joined(separator: " · "))
                    .font(.dahliaSecondary).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.edit) { model.edit(source) }
            }

        }
        .padding(.vertical, 4)
    }

    private func eventRow(_ event: AgentEventRecord) -> some View {
        DahliaBotEventRow(event: event, icon: eventIcon(event))
    }

    /// The source's logo; an answer the user gave in this panel has no source.
    private func eventIcon(_ event: AgentEventRecord) -> Image {
        guard let source = model.sources.first(where: { $0.id == event.sourceID }) else { return Image(systemName: "person.crop.circle") }
        if source.kind == "calendar" { return Image(systemName: "calendar") }
        return AgentMCPServiceLogo.image(for: model.services[source.server] ?? source.server)
    }
}

/// One recorded event: its source's icon, time, and note. Clicking it shows the whole note, and clicking again folds it.
private struct DahliaBotEventRow: View {
    let event: AgentEventRecord
    let icon: Image
    @State private var isExpanded = false
    @State private var isHovered = false

    var body: some View {
        Button { isExpanded.toggle() } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                icon
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                    // A handled event gets a dot on its icon, so the row's layout never changes with its state.
                    .overlay(alignment: .bottomTrailing) {
                        if event.handledAt != nil {
                            Circle().fill(.green)
                                .frame(width: 6, height: 6)
                                .overlay { Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1) }
                                .offset(x: 2, y: 2)
                        }
                    }
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                    .accessibilityHidden(true)
                Text(event.occurredAt, format: .dateTime.hour().minute())
                    .font(.dahliaSecondary).foregroundStyle(.secondary).monospacedDigit()
                Text(event.note)
                    .lineLimit(isExpanded ? nil : 3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .contentShape(.rect)
            .background(isHovered ? DahliaDesign.contentHighlightColor : .clear, in: .rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityValue(event.handledAt == nil ? L10n.agentAlwaysOnEventUnassigned : L10n.agentAlwaysOnEventProcessed)
        .accessibilityHint(isExpanded ? L10n.collapse : L10n.expand)
    }
}
