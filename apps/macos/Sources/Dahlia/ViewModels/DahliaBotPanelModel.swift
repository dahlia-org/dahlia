import AppKit
import Foundation
import Observation

/// An agent's side panel and its event source editor: the Items that need the user, its Tasks, the Sources intake
/// reads, `SOUL.md`, and the events intake recorded, all of the agent shown in `agentID`. The database and the home
/// folder are read off MainActor through `PiChatService`.
@MainActor
@Observable
final class DahliaBotPanelModel {
    typealias TaskPage = (active: [AgentTaskRecord], finished: [AgentTaskRecord])
    struct Draft: Equatable {
        var id: String?
        var name = ""
        var server = ""
        var instructions = ""
        var intervalMinutes = 15
        var allowedSenders = ""
        var allowedDomains = ""
        var dailyEnabled = true
        var dailyTime = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: .now) ?? .now
        var leadEnabled = true
        var leadHours = 24.0
        var kind = "mcp"
        /// `mail`, `slack`, or empty, as `AgentSourceRecord.service`.
        var service = ""
        var addressedOnly = true
        var slackScope = AgentSourceOptions.SlackScope.mentions
        var includeChannels = ""
        var excludeChannels = ""
        var weeklyEnabled = false
        var weekday = 2
        var weeklyTime = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: .now) ?? .now
        var acceptedOnly = false
    }

    static let intervals = [5, 15, 30, 60]
    /// The calendar Source's default name, in English like a connector's.
    static let calendarName = "Calendar"
    static let taskPage = 30

    var sources: [AgentSourceRecord] = []
    var events: [AgentEventRecord] = []
    var servers: [String] = []
    var connections: [String: String] = [:]
    /// Each server's service, for its logo and name.
    var services: [String: String] = [:]
    /// Each server's provider as the connector settings name it, to tell servers of one service apart.
    var providers: [String: String] = [:]
    var paused = false
    var draft: Draft?
    var items: [AgentItemRecord] = []
    /// Each Task's Thread, by Task, for the Items that belong to one.
    var taskThreads: [String: String] = [:]
    /// Typed answers to questions, by Item.
    var answers: [String: String] = [:]
    var activeTasks: [AgentTaskRecord] = []
    var finishedTasks: [AgentTaskRecord] = []
    var hasMoreFinishedTasks = false
    private(set) var isLoadingFinishedTasks = false
    var soul = ""
    var models: [CodexModel] = []
    private(set) var areModelSettingsLoaded = false
    /// Empty follows the default: Pi's model for intake, the conversation's for notices. Saved on the agent.
    private(set) var intakeModel = ""
    private(set) var unattendedModel = ""
    private(set) var intakeEffort = ""
    private(set) var unattendedEffort = ""
    /// Whether the agent picks each launched thread's model and effort. Saved on the agent.
    private(set) var smartRouting = false

    /// The text being edited, while the user edits `SOUL.md`.
    var soulDraft: String?
    var error: String?
    var isBusy = false

    /// The agent shown; changing it clears what the previous one showed.
    var agentID: String? {
        didSet {
            guard agentID != oldValue else { return }
            reset(for: agentID)
        }
    }

    init(
        loadAgent: @escaping @Sendable (String) async throws -> AgentRecord = { try await PiChatService.shared.agent($0) },
        saveAgentModel: @escaping @Sendable (String, AgentRecord.ModelUse, String, String) async throws -> Void = {
            try await PiChatService.shared.setAgentModel($0, use: $1, model: $2, effort: $3)
        },
        saveSmartRouting: @escaping @Sendable (String, Bool) async throws -> Void = {
            try await PiChatService.shared.setAgentSmartRouting($0, $1)
        },
        saveSoulFile: @escaping @Sendable (String, String) async throws -> Void = {
            try await PiChatService.shared.saveBotSoul($0, $1)
        },
        loadTasks: @escaping @Sendable (String, Int) async throws -> TaskPage = {
            try await PiChatService.shared.loadBotTasks($0, limit: $1)
        },
        loadConnectorSettings: @escaping @Sendable () async -> (settings: AgentMCPSettings, providers: [AgentMCPProvider]) = {
            await PiChatService.shared.loadBotConnectors()
        }
    ) {
        self.loadAgent = loadAgent
        self.saveAgentModel = saveAgentModel
        self.saveSmartRouting = saveSmartRouting
        self.saveSoulFile = saveSoulFile
        self.loadTasks = loadTasks
        self.loadConnectorSettings = loadConnectorSettings
    }

    private let loadAgent: @Sendable (String) async throws -> AgentRecord
    private let saveAgentModel: @Sendable (String, AgentRecord.ModelUse, String, String) async throws -> Void
    private let saveSmartRouting: @Sendable (String, Bool) async throws -> Void
    private var modelSettingsRevision = 0
    private var pendingModelSaves = 0
    private var taskGeneration = 0
    /// Distinguishes selection lifetimes, including leaving an agent and returning before work completes.
    private var agentGeneration = 0
    private var finishedTaskLimit = taskPage
    private let loadTasks: @Sendable (String, Int) async throws -> TaskPage
    private let loadConnectorSettings: @Sendable () async -> (settings: AgentMCPSettings, providers: [AgentMCPProvider])
    private let saveSoulFile: @Sendable (String, String) async throws -> Void

    private func reset(for _: String?) {
        agentGeneration += 1
        areModelSettingsLoaded = false
        pendingModelSaves = 0
        modelSettingsRevision += 1
        taskGeneration += 1
        isBusy = false
        isLoadingFinishedTasks = false
        finishedTaskLimit = Self.taskPage
        (sources, events, items, taskThreads, answers) = ([], [], [], [:], [:])
        (activeTasks, finishedTasks, hasMoreFinishedTasks) = ([], [], false)
        (soul, soulDraft, draft, error) = ("", nil, nil, nil)
        (intakeModel, intakeEffort, unattendedModel, unattendedEffort) = ("", "", "", "")
        smartRouting = false
    }

    /// A model and its effort are one choice: following the default clears the effort, and a model takes its own default
    /// effort when the saved one is not among its levels.
    func setIntakeModel(_ selected: String) {
        guard areModelSettingsLoaded else { return }
        intakeModel = selected
        intakeEffort = effort(intakeEffort, for: selected)
        saveModel(.intake)
    }

    func setUnattendedModel(_ selected: String) {
        guard areModelSettingsLoaded else { return }
        unattendedModel = selected
        unattendedEffort = effort(unattendedEffort, for: selected)
        saveModel(.unattended)
    }

    func setIntakeEffort(_ effort: String) {
        guard areModelSettingsLoaded else { return }
        intakeEffort = effort
        saveModel(.intake)
    }

    func setUnattendedEffort(_ effort: String) {
        guard areModelSettingsLoaded else { return }
        unattendedEffort = effort
        saveModel(.unattended)
    }

    func setSmartRouting(_ enabled: Bool) {
        guard areModelSettingsLoaded, let agentID else { return }
        smartRouting = enabled
        saveModelSetting { [saveSmartRouting] in try await saveSmartRouting(agentID, enabled) }
    }

    private func saveModel(_ use: AgentRecord.ModelUse) {
        guard let agentID else { return }
        let (model, effort) = switch use {
        case .intake: (intakeModel, intakeEffort)
        case .unattended: (unattendedModel, unattendedEffort)
        }
        saveModelSetting { [saveAgentModel] in try await saveAgentModel(agentID, use, model, effort) }
    }

    private func saveModelSetting(_ save: @escaping @Sendable () async throws -> Void) {
        modelSettingsRevision += 1
        pendingModelSaves += 1
        let generation = agentGeneration
        Task {
            defer { if generation == agentGeneration { pendingModelSaves -= 1 } }
            do {
                try await save()
            } catch {
                guard generation == agentGeneration else { return }
                self.error = error.localizedDescription
            }
        }
    }

    /// A periodic read must not replace a choice edited while it was awaiting the database.
    func refreshModelSettings() async throws {
        guard let agentID, pendingModelSaves == 0 else { return }
        let generation = agentGeneration
        let revision = modelSettingsRevision
        let agent = try await loadAgent(agentID)
        guard generation == agentGeneration, revision == modelSettingsRevision else { return }
        (intakeModel, intakeEffort) = (agent.intakeModel ?? "", agent.intakeEffort ?? "")
        (unattendedModel, unattendedEffort) = (agent.unattendedModel ?? "", agent.unattendedEffort ?? "")
        smartRouting = agent.smartRouting
        areModelSettingsLoaded = true
    }

    private func effort(_ current: String, for selected: String) -> String {
        guard let chosen = models.first(where: { $0.model == selected }) else { return selected.isEmpty ? "" : current }
        return chosen.supportedReasoningEfforts.contains { $0.reasoningEffort == current } ? current : chosen.defaultReasoningEffort
    }

    func editSoul() {
        soulDraft = soul
    }

    func saveSoul() async {
        guard let text = soulDraft, let agentID else { return }
        let generation = agentGeneration
        do {
            try await saveSoulFile(agentID, text)
            guard generation == agentGeneration else { return }
            soul = text
            soulDraft = nil
        } catch {
            guard generation == agentGeneration else { return }
            self.error = error.localizedDescription
        }
    }

    func showSoulInFinder() async {
        guard let agentID, let url = try? await PiChatService.shared.botSoulURL(agentID) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func loadMoreFinishedTasks() async {
        guard !isLoadingFinishedTasks, !finishedTasks.isEmpty else { return }
        let generation = agentGeneration
        isLoadingFinishedTasks = true
        defer { if generation == agentGeneration { isLoadingFinishedTasks = false } }
        let previousLimit = finishedTaskLimit
        finishedTaskLimit = max(finishedTaskLimit, finishedTasks.count) + Self.taskPage
        do {
            try await refreshTasks()
        } catch {
            guard generation == agentGeneration else { return }
            finishedTaskLimit = previousLimit
            self.error = error.localizedDescription
        }
    }

    /// Every request reads the entire visible range, so newer refreshes preserve pending pagination and saved changes.
    func refreshTasks() async throws {
        guard let agentID else { return }
        taskGeneration += 1
        let generation = taskGeneration
        let limit = max(finishedTaskLimit, finishedTasks.count)
        let tasks: TaskPage
        do {
            tasks = try await loadTasks(agentID, limit)
        } catch {
            guard generation == taskGeneration else { return }
            throw error
        }
        guard generation == taskGeneration else { return }
        activeTasks = tasks.active
        finishedTasks = tasks.finished
        hasMoreFinishedTasks = tasks.finished.count == limit
    }

    /// Answers the revision on screen; when the Item changed meanwhile, nothing is applied and the list reloads.
    func answer(_ item: AgentItemRecord, with text: String) async {
        let generation = agentGeneration
        await perform { inbox in _ = try inbox.answer(itemID: item.id, revision: item.revision, answer: text) }
        guard generation == agentGeneration else { return }
        answers[item.id] = nil
    }

    /// The user ends a Task; its thread stays as it is.
    func finish(_ task: AgentTaskRecord) async {
        await perform { inbox in try inbox.finishTask(taskID: task.id, status: "done") }
    }

    func dismiss(_ item: AgentItemRecord) async {
        await perform { inbox in _ = try inbox.dismiss(itemID: item.id, revision: item.revision) }
    }

    func refresh() async {
        guard let agentID else { return }
        let generation = agentGeneration
        do {
            try await refreshModelSettings()
            guard generation == agentGeneration else { return }
            let loaded = try await PiChatService.shared.loadAlwaysOnSettings(agentID)
            let inbox = try await PiChatService.shared.loadBotInbox(agentID)
            // The window may have moved to another agent while this one loaded.
            guard generation == agentGeneration else { return }
            (sources, events, paused) = loaded
            (items, taskThreads) = inbox
            try await refreshTasks()
            guard generation == agentGeneration else { return }
            if soulDraft == nil {
                let soul = try await PiChatService.shared.loadBotSoul(agentID)
                guard generation == agentGeneration else { return }
                self.soul = soul
            }
            let models = await (try? PiRuntimeService.shared.models(forceRefresh: false))?.filter { !$0.hidden } ?? []
            guard generation == agentGeneration else { return }
            self.models = models
            await refreshConnectors()
        } catch {
            guard generation == agentGeneration else { return }
            self.error = error.localizedDescription
        }
    }

    func refreshConnectors() async {
        let generation = agentGeneration
        let snapshot = await loadConnectorSettings()
        guard generation == agentGeneration, !Task.isCancelled else { return }
        loadConnectors(snapshot.settings, providers: snapshot.providers)
    }

    func loadConnectors(_ settings: AgentMCPSettings, providers: [AgentMCPProvider]) {
        servers = Self.sourceServers(in: settings, providers: providers)
        services = Dictionary(settings.servers.map { ($0.name, $0.service) }) { first, _ in first }
        self.providers = Dictionary(settings.servers.map { server in
            (server.name, server.direct != nil ? L10n.mcpDirectSection : server.providerID.flatMap(settings.provider(id:))?.host ?? "")
        }) { first, _ in first }
        // Excluding a connector from new choices does not retire an existing source's connection.
        connections = Dictionary(uniqueKeysWithValues: settings.piServers.keys.compactMap { name in
            settings.connectionID(for: name).map { (name, $0) }
        })
    }

    static func sourceServers(in settings: AgentMCPSettings, providers: [AgentMCPProvider]) -> [String] {
        let excluded = Set(["system.ai.web_search", "system.ai.google_drive", "system.ai.google_calendar"])
        let registered = settings.piServers
        // Match Settings: direct servers first, then provider sections with built-in services before custom services.
        let ordered = settings.servers.filter { $0.direct != nil } + providers.flatMap { provider in
            settings.servers.filter { $0.direct == nil && $0.providerID == provider.id }.sorted { lhs, rhs in
                if lhs.service.hasPrefix("system.ai.") != rhs.service.hasPrefix("system.ai.") { return lhs.service.hasPrefix("system.ai.") }
                return lhs.service < rhs.service
            }
        }
        return ordered.filter { registered[$0.name] != nil && !excluded.contains($0.service) }.map(\.name)
    }

    /// What a server reads from: every Slack server is one choice and every mail server another, so the user picks the
    /// kind and gets its first server without choosing each time. Any other server is its own choice.
    static func group(of server: String, service: String) -> String {
        let name = "\(server) \(service)".lowercased()
        if name.contains("slack") { return "slack" }
        if ["gmail", "mail", "outlook"].contains(where: name.contains) { return "mail" }
        return server
    }

    func group(_ server: String) -> String {
        Self.group(of: server, service: services[server] ?? server)
    }

    func groupDisplayName(_ server: String) -> String {
        switch group(server) {
        case "slack": L10n.slack
        case "mail": L10n.agentAlwaysOnMail
        default: displayName(server)
        }
    }

    /// `servers` by group, in the order of each group's first server.
    var serverGroups: [[String]] {
        var groups: [[String]] = []
        var index: [String: Int] = [:]
        for server in servers {
            let key = group(server)
            if let position = index[key] { groups[position].append(server) } else {
                index[key] = groups.count
                groups.append([server])
            }
        }
        // Mail before Slack, then other servers in their order, after the calendar the editor puts first.
        return groups.filter { group($0[0]) == "mail" } + groups.filter { group($0[0]) == "slack" }
            + groups.filter { !["mail", "slack"].contains(group($0[0])) }
    }

    func setEnabled(_ enabled: Bool) async {
        await perform { inbox in try inbox.setPaused(!enabled) }
    }

    func edit(_ source: AgentSourceRecord?) {
        error = nil
        guard let source else {
            draft = Draft()
            chooseCalendar()
            return
        }
        let senders = (try? JSONDecoder().decode([String].self, from: Data(source.allowedSenders.utf8))) ?? []
        var edited = Draft(
            id: source.id, name: source.name, server: source.server, instructions: source.instructions,
            intervalMinutes: source.intervalMinutes, allowedSenders: senders.joined(separator: ", "), kind: source.kind,
            service: source.service
        )
        let options = source.sourceOptions
        edited.dailyEnabled = source.dailyAt != nil
        edited.leadEnabled = source.leadHours != nil
        edited.leadHours = source.leadHours ?? 24
        if let time = Self.time(source.dailyAt) { edited.dailyTime = time }
        edited.addressedOnly = options.addressedOnly == true
        edited.allowedDomains = (options.allowedDomains ?? []).joined(separator: ", ")
        edited.slackScope = options.slackScope ?? .mentions
        edited.includeChannels = (options.includeChannels ?? []).joined(separator: ", ")
        edited.excludeChannels = (options.excludeChannels ?? []).joined(separator: ", ")
        edited.weeklyEnabled = options.weeklyAt != nil
        edited.weekday = options.weekday ?? 2
        if let time = Self.time(options.weeklyAt) { edited.weeklyTime = time }
        edited.acceptedOnly = options.acceptedOnly == true
        draft = edited
    }

    /// A new source's server; the name and the kind of settings follow it until the user changes the name.
    func choose(server: String) {
        guard var changed = draft, changed.id == nil else { return }
        let previousName = changed.kind == "calendar" ? Self.calendarName : displayName(changed.server)
        if changed.name.isEmpty || changed.name == previousName { changed.name = displayName(server) }
        changed.server = server
        changed.kind = "mcp"
        changed.service = ["mail", "slack"].contains(group(server)) ? group(server) : ""
        draft = changed
    }

    func chooseCalendar() {
        guard var changed = draft, changed.id == nil else { return }
        if changed.name.isEmpty || changed.name == displayName(changed.server) { changed.name = Self.calendarName }
        changed.kind = "calendar"
        changed.server = ""
        changed.service = ""
        draft = changed
    }

    /// A server as the connector choice shows it: its name, then its provider.
    func choiceName(_ server: String) -> String {
        providers[server].flatMap(\.nilIfBlank).map { "\(server) (\($0))" } ?? server
    }

    func sourceChoiceName(_ sourceID: String) -> String {
        guard let source = sources.first(where: { $0.id == sourceID }) else { return L10n.agentAlwaysOnConnectionUnavailable }
        guard !source.connectionID.isEmpty, connections[source.server] == source.connectionID else {
            return "\(source.server) (\(L10n.agentAlwaysOnConnectionUnavailable))"
        }
        return choiceName(source.server)
    }

    func displayName(_ server: String) -> String {
        server.isEmpty ? "" : AgentMCPServer.displayName(for: services[server] ?? server)
    }

    /// The Source the draft saves. The preview shows this Source's prompt, so it is what intake will send.
    func draftSource(_ draft: Draft, now: Date = .now) -> AgentSourceRecord {
        let isCalendar = draft.kind == "calendar"
        let existing = sources.first { $0.id == draft.id }
        // Slack and the calendar have no sender limit.
        let senders = draft.kind == "calendar" || draft.service == "slack" ? [] : draft.allowedSenders.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var source = AgentSourceRecord(
            id: existing?.id ?? draft.id ?? "", agentID: agentID ?? "",
            name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
                ?? (isCalendar ? Self.calendarName : displayName(draft.server)),
            server: draft.server, instructions: draft.instructions.trimmingCharacters(in: .whitespacesAndNewlines),
            intervalMinutes: draft.intervalMinutes, allowedSenders: String(
                decoding: (try? JSONEncoder().encode(senders)) ?? Data("[]".utf8),
                as: UTF8.self
            ),
            cursor: existing?.cursor, enabled: existing?.enabled ?? true,
            lastIntakeAt: existing?.lastIntakeAt,
            createdAt: existing?.createdAt ?? now, updatedAt: now
        )
        source.connectionID = isCalendar ? "" : existing?.connectionID ?? connections[draft.server] ?? ""
        source.kind = isCalendar ? "calendar" : "mcp"
        source.service = existing?.service ?? draft.service
        var options = AgentSourceOptions()
        switch source.service {
        case "mail":
            options.addressedOnly = draft.addressedOnly
            options.allowedDomains = Self.domains(draft.allowedDomains)
        case "slack":
            options.slackScope = draft.slackScope
            options.includeChannels = Self.channels(draft.includeChannels)
            options.excludeChannels = Self.channels(draft.excludeChannels)
        default: break
        }
        if isCalendar {
            source.dailyAt = draft.dailyEnabled ? Self.clock(draft.dailyTime) : nil
            source.leadHours = draft.leadEnabled ? draft.leadHours : nil
            if draft.weeklyEnabled {
                options.weeklyAt = Self.clock(draft.weeklyTime)
                options.weekday = draft.weekday
            }
            options.acceptedOnly = draft.acceptedOnly
        }
        source.sourceOptions = options
        return source
    }

    /// The draft's intake prompt, as intake will send it.
    var draftPrompt: String {
        guard let draft else { return "" }
        return AgentSourcePrompt.intake(draftSource(draft), since: L10n.agentSourcePromptSince)
    }

    /// A Source's settings in a line, for its card.
    static func summary(_ source: AgentSourceRecord) -> String {
        let options = source.sourceOptions
        let choice: String? = switch source.service {
        case "mail": options.addressedOnly == true ? L10n.agentMailAddressedOnly : nil
        case "slack": options.slackScope.map(scopeName)
        default: nil
        }
        if source.kind == "calendar" { return L10n.agentCalendarScheduleHelp }
        return [choice, source.instructions.nilIfBlank].compactMap(\.self).joined(separator: " · ")
    }

    static func scopeName(_ scope: AgentSourceOptions.SlackScope) -> String {
        switch scope {
        case .mentions: L10n.agentSlackScopeMentions
        case .joined: L10n.agentSlackScopeJoined
        case .all: L10n.agentSlackScopeAll
        }
    }

    /// Channel names as the user typed them, without `#`, spaces, or empty entries.
    nonisolated static func channels(_ text: String) -> [String] {
        text.split(separator: ",").map {
            String($0.trimmingCharacters(in: .whitespaces).drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
    }

    nonisolated static func domains(_ text: String) -> [String] {
        text.split(separator: ",").map {
            String($0.trimmingCharacters(in: .whitespaces).drop { $0 == "@" }).trimmingCharacters(in: .whitespaces).lowercased()
        }.filter { !$0.isEmpty }
    }

    private static func clock(_ date: Date) -> String {
        let time = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", time.hour ?? 8, time.minute ?? 0)
    }

    private static func time(_ clock: String?) -> Date? {
        guard let clock, let components = AgentInboxService.dailyComponents(clock) else { return nil }
        return Calendar.current.date(bySettingHour: components.hour, minute: components.minute, second: 0, of: .now)
    }

    func saveDraft() async {
        guard let draft, agentID != nil else { return }
        let generation = agentGeneration
        var source = draftSource(draft)
        // Another MCP server has no settings of its own, so what to read is the whole request.
        guard !source.name.isEmpty, source.kind == "calendar" || (!source.server.isEmpty && !source.connectionID.isEmpty
            && (!source.service.isEmpty || !source.instructions.isEmpty)) else {
            error = L10n.agentAlwaysOnRequired
            return
        }
        if source.id.isEmpty { source.id = UUID.v7().uuidString }
        let saved = source
        await perform { inbox in try inbox.saveSource(saved) }
        guard generation == agentGeneration else { return }
        if error == nil { self.draft = nil }
    }

    func setEnabled(_ source: AgentSourceRecord, enabled: Bool) async {
        var changed = source
        changed.enabled = enabled
        changed.updatedAt = .now
        let saved = changed
        await perform { inbox in try inbox.saveSource(saved) }
    }

    func setInterval(_ source: AgentSourceRecord, minutes: Int) async {
        guard minutes != source.intervalMinutes else { return }
        var changed = source
        changed.intervalMinutes = minutes
        changed.updatedAt = .now
        let saved = changed
        await perform { inbox in try inbox.saveSource(saved) }
    }

    func deleteDraft() async {
        guard let id = draft?.id else { return }
        let generation = agentGeneration
        await perform { inbox in try inbox.deleteSource(id: id) }
        guard generation == agentGeneration else { return }
        if error == nil { draft = nil }
    }

    private func perform(_ change: @escaping @Sendable (AgentInboxService) throws -> Void) async {
        guard let agentID else { return }
        let generation = agentGeneration
        isBusy = true
        defer { if generation == agentGeneration { isBusy = false } }
        do {
            try await PiChatService.shared.updateAlwaysOnSettings(agentID, change: change)
            guard generation == agentGeneration else { return }
            error = nil
        } catch {
            guard generation == agentGeneration else { return }
            self.error = error.localizedDescription
        }
        await refresh()
    }
}
