import SwiftUI

/// An agent's side panel, beside its thread. Its inbox (what waits for the user, its Tasks, the events intake recorded)
/// comes first; its settings (event sources, `SOUL.md`, its name and picture, deleting it) sit apart,
/// behind the header's switch. Its model belongs to the window, which shows the editors over everything.
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
    let agents: AgentsModel
    @State private var tab = Tab.inbox
    /// Only one event shows its whole note at a time.
    @State private var expandedEventID: String?

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
            .formStyle(.grouped).toggleStyle(.dahliaSwitch).buttonStyle(.dahlia()).font(.dahliaBody).disabled(model.isBusy)
            // The header's background is clear, so rows scrolled past the Form's top would show through the tabs.
            .clipped()
        }
        .task(id: model.agentID) {
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    @ViewBuilder
    private var activity: some View {
        Section {
            if model.items.isEmpty { Text(L10n.agentBotInboxEmpty).foregroundStyle(.secondary) }
            ForEach(model.items) { item in itemRow(item) }
            if model.hasMoreItems {
                Button(L10n.loadMore) { model.loadMoreItems() }
            }
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
        let agent = agents.summaries.first { $0.id == model.agentID }?.agent
        // As Orca's: the agent's picture and name head its settings, changed where they are shown.
        if let agent {
            Section {
                AgentIdentityRow(agent: agent, identity: agents.identity(for: agent)).id(agent.id)
                modelPicker(
                    L10n.agentBotUnattendedModel, help: L10n.agentBotUnattendedModelHelp, fallback: L10n.agentBotModelConversation,
                    selection: Binding(get: { model.unattendedModel }, set: { model.setUnattendedModel($0) }),
                    effort: Binding(get: { model.unattendedEffort }, set: { model.setUnattendedEffort($0) })
                )
                .disabled(!model.areModelSettingsLoaded)
            }
        }
        // One group, with a row per source.
        Section {
            ForEach(model.sources) { source in sourceCard(source) }
            if model.servers.isEmpty { Text(L10n.agentAlwaysOnNoServers).foregroundStyle(.secondary) }
            if let error = model.error, model.draft == nil { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            modelPicker(
                L10n.agentBotIntakeModel, help: L10n.agentBotIntakeModelHelp, fallback: L10n.agentBotModelDefault,
                selection: Binding(get: { model.intakeModel }, set: { model.setIntakeModel($0) }),
                effort: Binding(get: { model.intakeEffort }, set: { model.setIntakeEffort($0) })
            )
            .disabled(!model.areModelSettingsLoaded)
        } header: {
            HStack {
                Text(L10n.agentAlwaysOnSources).font(.dahliaSectionHeader)
                SettingsInfoButton(help: L10n.agentAlwaysOnHelp)
                Spacer()
                Button(L10n.add, systemImage: "plus") { model.edit(nil) }.font(.dahliaBody)
            }
        }
        Section {
            Toggle(isOn: Binding(get: { model.smartRouting }, set: { model.setSmartRouting($0) })) {
                HStack {
                    Text(L10n.agentBotSmartRouting)
                    SettingsInfoButton(help: L10n.agentBotSmartRoutingHelp)
                }
            }
            .toggleStyle(.dahliaSwitch)
            LabeledContent {
                Picker(L10n.agentBotWorkerApproval, selection: Binding(
                    get: { model.workerApprovalMethod }, set: { model.setWorkerApprovalMethod($0) }
                )) {
                    ForEach(CodexChatApprovalMethod.allCases) { Label($0.title, systemImage: $0.systemImage).font(.dahliaBody).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            } label: {
                HStack {
                    Text(L10n.agentBotWorkerApproval)
                    SettingsInfoButton(help: L10n.agentBotWorkerApprovalHelp)
                }
            }
        } header: {
            AgentSectionHeader(title: L10n.agentBotWorkers) { EmptyView() }
        }
        .disabled(!model.areModelSettingsLoaded)
        soulSection(deleting: agent)
    }

    /// `SOUL.md`; its footer, the last thing in the settings, holds deleting the agent, outside a group as Orca's.
    private func soulSection(deleting agent: AgentRecord?) -> some View {
        Section {
            soulContent
        } header: {
            HStack {
                Text(L10n.agentBotSoul).font(.dahliaSectionHeader)
                SettingsInfoButton(help: L10n.agentBotSoulHelp)
            }
        } footer: {
            if let agent {
                DeleteAgentButton { agents.pendingDeletion = agent }
                    .padding(.top, 12)
            }
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

    @ViewBuilder
    private var soulContent: some View {
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
                Button(L10n.save) { Task { await model.saveSoul() } }.buttonStyle(.dahlia(.primary)).keyboardShortcut(.defaultAction)
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
                            .buttonStyle(.dahlia(.primary))
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
                    Text(DahliaBotPanelModel.summary(source)).foregroundStyle(.secondary).lineLimit(2)
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
                // Calendar sources record their signals without an intake run.
                if source.kind != "calendar" {
                    Button(L10n.agentOpenIntakeThread) { Task { await model.openIntakeThread(source) } }
                }
                Button(L10n.edit) { model.edit(source) }
            }

        }
        .padding(.vertical, 4)
    }

    private func eventRow(_ event: AgentEventRecord) -> some View {
        DahliaBotEventRow(event: event, icon: eventIcon(event), isExpanded: expandedEventID == event.id) {
            expandedEventID = expandedEventID == event.id ? nil : event.id
        }
    }

    /// The source's logo; an answer the user gave in this panel has no source.
    private func eventIcon(_ event: AgentEventRecord) -> Image {
        guard let source = model.sources.first(where: { $0.id == event.sourceID }) else { return Image(systemName: "person.crop.circle") }
        if source.kind == "calendar" { return Image(systemName: "calendar") }
        return AgentMCPServiceLogo.image(for: model.services[source.server] ?? source.server)
    }
}

/// One recorded event, limited to two lines. Clicking it shows the whole note; a linked event opens its source item
/// from the link under its icon and time.
struct DahliaBotEventRow: View {
    let event: AgentEventRecord
    let icon: Image
    let isExpanded: Bool
    let toggle: () -> Void
    @State private var isHovered = false

    /// Calendar's `ical` scheme opens Apple Calendar events; every other link is a provider's web page.
    private var url: URL? {
        guard let url = event.url.flatMap(URL.init(string:)) else { return nil }
        switch url.scheme?.lowercased() {
        case "https": return url.host() != nil ? url : nil
        case "ical": return url
        default: return nil
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
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
                }
                if let url { DahliaBotEventLink(url: url) }
            }
            Button(action: toggle) {
                Text(event.note)
                    .lineLimit(isExpanded ? nil : 2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .focusable()
            .onKeyPress(keys: [.space, .return], phases: .down) { _ in
                toggle()
                return .handled
            }
            .accessibilityHint(isExpanded ? L10n.collapse : L10n.expand)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .contentShape(.rect)
        .background(isHovered ? DahliaDesign.contentHighlightColor : .clear, in: .rect(cornerRadius: 6))
        .onHover { isHovered = $0 }
        // The note and Open are sibling buttons; clicking elsewhere in the row also toggles its note.
        .onTapGesture(perform: toggle)
        .accessibilityElement(children: .contain)
        .accessibilityValue(event.handledAt == nil ? L10n.agentAlwaysOnEventUnassigned : L10n.agentAlwaysOnEventProcessed)
    }
}

/// Text-only link to an event's source item. Its hover is stronger than the row's, so it shows inside a hovered row.
private struct DahliaBotEventLink: View {
    let url: URL
    @State private var isHovered = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button { openURL(url) } label: {
            Label(L10n.open, systemImage: "arrow.up.right")
                .font(.dahliaSecondary)
                .foregroundStyle(isHovered ? .primary : .secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(isHovered ? DahliaDesign.chipHoverColor : .clear, in: .rect(cornerRadius: 4))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .focusable()
        .onKeyPress(keys: [.space, .return], phases: .down) { _ in
            openURL(url)
            return .handled
        }
        .onHover { isHovered = $0 }
        // Aligns the link's text with the icon above it, not its padding.
        .padding(.leading, -4)
    }
}

/// The agent's picture and name at the top of its settings, as Orca's: the picture opens the picker, the name is typed
/// over, and each is saved when the picker closes or the name is submitted or left.
struct AgentIdentityRow: View {
    let agent: AgentRecord
    @Bindable var identity: AgentIdentityModel
    @State private var isPickingAvatar = false
    @State private var isAvatarHovered = false
    @State private var isEditingName = false
    @State private var isNameHovered = false
    @FocusState private var isNameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button { isPickingAvatar = true } label: {
                    AgentAvatarView(avatar: identity.avatar, color: identity.color, size: Self.avatarSize)
                        .overlay {
                            if isAvatarHovered || isPickingAvatar {
                                RoundedRectangle(cornerRadius: AgentAvatarView.cornerRadius(Self.avatarSize), style: .continuous)
                                    .fill(.black.opacity(0.35))
                                Image(systemName: "pencil").dahliaFixedSymbol().foregroundStyle(.white)
                            }
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .onHover { isAvatarHovered = $0 }
                .pointerStyle(.link)
                .help(L10n.agentChangeAvatar)
                .accessibilityLabel(L10n.agentChangeAvatar)
                .popover(isPresented: $isPickingAvatar, arrowEdge: .bottom) {
                    AgentAvatarPicker(avatar: $identity.avatar, color: $identity.color)
                }
                // The name reads as text, with a pencil on hover; clicking it opens a bordered field, as Orca's.
                if isEditingName {
                    TextField(L10n.agentName, text: $identity.name, prompt: Text(L10n.agentName))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .focused($isNameFocused)
                        .onAppear { isNameFocused = true }
                        .onSubmit { isNameFocused = false }
                        // A click anywhere else saves and closes it too; clicking empty space would not take the focus.
                        .dismissOnOutsideClick { isNameFocused = false }
                        .onExitCommand {
                            identity.name = identity.agent.name
                            isNameFocused = false
                        }
                        .onDisappear {
                            // Switching tabs can remove the field before its focus change is delivered.
                            if isEditingName { identity.save() }
                        }
                } else {
                    Button { isEditingName = true } label: {
                        HStack(spacing: 6) {
                            Text(identity.name).lineLimit(1)
                            Image(systemName: "pencil")
                                .dahliaFixedSymbol()
                                .foregroundStyle(.secondary)
                                .opacity(isNameHovered ? 1 : 0)
                            Spacer(minLength: 0)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .onHover { isNameHovered = $0 }
                    .pointerStyle(.link)
                    .help(L10n.agentName)
                }
            }
            .disabled(identity.isSaving)
            if let error = identity.error { Text(error).font(.dahliaBody).foregroundStyle(.red).textSelection(.enabled) }
        }
        .font(Self.nameFont)
        .onAppear { identity.refresh(agent, editingName: false, pickingAvatar: false) }
        .onChange(of: agent) { identity.refresh(agent, editingName: isEditingName, pickingAvatar: isPickingAvatar) }
        .onChange(of: isPickingAvatar) { if !isPickingAvatar { identity.save() } }
        .onChange(of: isNameFocused) {
            guard !isNameFocused else { return }
            identity.save()
            isEditingName = false
        }
    }

    private static let avatarSize: CGFloat = 32
    /// The base size plus 2 pt, as Orca's.
    private static var nameFont: Font { .system(size: DahliaTypography.size(offset: 2), weight: .semibold) }

}

/// Deleting the agent, as Orca's: red text with no fill, tinted red while the pointer is over it.
private struct DeleteAgentButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(role: .destructive, action: action) {
            Label(L10n.agentDelete, systemImage: "trash")
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.red.opacity(isHovered ? 0.1 : 0), in: .rect(cornerRadius: DahliaDesign.Button.cornerRadius))
                .contentShape(.rect(cornerRadius: DahliaDesign.Button.cornerRadius))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.red)
        .onHover { isHovered = $0 }
        .pointerStyle(.link)
        // The padding sits inside the tint, so the text lines up with the groups above.
        .padding(.leading, -10)
    }
}
