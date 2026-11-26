import AppKit
import Foundation
import Observation

/// Super Agent's side panel and its event source editor: the Items that need the user, its Tasks, the Sources intake
/// reads, `SOUL.md`, and the events intake recorded. The database and the home folder are read off MainActor through
/// `PiChatService`.
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
        var dailyEnabled = true
        var dailyTime = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: .now) ?? .now
        var leadEnabled = true
        var leadHours = 24.0
        var kind = "mcp"
    }

    static let intervals = [5, 15, 30, 60]
    static let taskPage = 30

    var sources: [AgentSourceRecord] = []
    var events: [AgentEventRecord] = []
    var servers: [String] = []
    var connections: [String: String] = [:]
    /// Each server's service, for its logo and name.
    var services: [String: String] = [:]
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
    /// Empty follows the default: Pi's model for intake, the conversation's for notices.
    var intakeModel: String {
        didSet { defaults.set(intakeModel, forKey: AgentBotSettings.intakeModelKey(for: AppAccount.key)) }
    }

    var unattendedModel: String {
        didSet { defaults.set(unattendedModel, forKey: AgentBotSettings.unattendedModelKey(for: AppAccount.key)) }
    }

    var intakeEffort: String {
        didSet { defaults.set(intakeEffort, forKey: AgentBotSettings.intakeEffortKey(for: AppAccount.key)) }
    }

    var unattendedEffort: String {
        didSet { defaults.set(unattendedEffort, forKey: AgentBotSettings.unattendedEffortKey(for: AppAccount.key)) }
    }

    /// The text being edited, while the user edits `SOUL.md`.
    var soulDraft: String?
    var error: String?
    var isBusy = false

    init(
        defaults: UserDefaults = .standard,
        loadTasks: @escaping @Sendable (Int) async throws -> TaskPage = {
            try await PiChatService.shared.loadBotTasks(limit: $0)
        }
    ) {
        self.defaults = defaults
        self.loadTasks = loadTasks
        intakeModel = AgentBotSettings.model(AgentBotSettings.intakeModelKey(for: AppAccount.key), defaults: defaults) ?? ""
        unattendedModel = AgentBotSettings.model(AgentBotSettings.unattendedModelKey(for: AppAccount.key), defaults: defaults) ?? ""
        intakeEffort = AgentBotSettings.model(AgentBotSettings.intakeEffortKey(for: AppAccount.key), defaults: defaults) ?? ""
        unattendedEffort = AgentBotSettings.model(AgentBotSettings.unattendedEffortKey(for: AppAccount.key), defaults: defaults) ?? ""
    }

    private var taskGeneration = 0
    private var finishedTaskLimit = taskPage
    private let loadTasks: @Sendable (Int) async throws -> TaskPage
    private let defaults: UserDefaults

    /// A model and its effort are one choice: following the default clears the effort, and a model takes its own default
    /// effort when the saved one is not among its levels.
    func setIntakeModel(_ selected: String) {
        intakeModel = selected
        intakeEffort = effort(intakeEffort, for: selected)
    }

    func setUnattendedModel(_ selected: String) {
        unattendedModel = selected
        unattendedEffort = effort(unattendedEffort, for: selected)
    }

    private func effort(_ current: String, for selected: String) -> String {
        guard let chosen = models.first(where: { $0.model == selected }) else { return selected.isEmpty ? "" : current }
        return chosen.supportedReasoningEfforts.contains { $0.reasoningEffort == current } ? current : chosen.defaultReasoningEffort
    }

    func editSoul() {
        soulDraft = soul
    }

    func saveSoul() async {
        guard let text = soulDraft else { return }
        do {
            try await PiChatService.shared.saveBotSoul(text)
            soul = text
            soulDraft = nil
        } catch { self.error = error.localizedDescription }
    }

    func showSoulInFinder() async {
        guard let url = try? await PiChatService.shared.botSoulURL() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Starts the conversation over; returns the new thread to open.
    func reset() async -> String? {
        guard !isBusy else { return nil }
        isBusy = true
        defer { isBusy = false }
        do {
            return try await PiChatService.shared.resetBotThread()
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    func loadMoreFinishedTasks() async {
        guard !isLoadingFinishedTasks, !finishedTasks.isEmpty else { return }
        isLoadingFinishedTasks = true
        defer { isLoadingFinishedTasks = false }
        let previousLimit = finishedTaskLimit
        finishedTaskLimit = max(finishedTaskLimit, finishedTasks.count) + Self.taskPage
        do {
            try await refreshTasks()
        } catch {
            finishedTaskLimit = previousLimit
            self.error = error.localizedDescription
        }
    }

    /// Every request reads the entire visible range, so newer refreshes preserve pending pagination and saved changes.
    func refreshTasks() async throws {
        taskGeneration += 1
        let generation = taskGeneration
        let limit = max(finishedTaskLimit, finishedTasks.count)
        let tasks: TaskPage
        do {
            tasks = try await loadTasks(limit)
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
        await perform { inbox in _ = try inbox.answer(itemID: item.id, revision: item.revision, answer: text) }
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
        do {
            let loaded = try await PiChatService.shared.loadAlwaysOnSettings()
            (sources, events, paused) = loaded
            (items, taskThreads) = try await PiChatService.shared.loadBotInbox()
            try await refreshTasks()
            if soulDraft == nil { soul = try await PiChatService.shared.loadBotSoul() }
            models = await (try? PiRuntimeService.shared.models(forceRefresh: false))?.filter { !$0.hidden } ?? []
            // Only servers with a sign-in reach mcp.json, so only they can be read.
            let settings = AgentMCPSettings.load()
            servers = Self.sourceServers(in: settings)
            services = Dictionary(settings.servers.map { ($0.name, $0.service) }) { first, _ in first }
            connections = Dictionary(uniqueKeysWithValues: servers.compactMap { name in settings.connectionID(for: name).map { (name, $0) } })
        } catch { self.error = error.localizedDescription }
    }

    static func sourceServers(in settings: AgentMCPSettings) -> [String] {
        let excluded = Set(["system.ai.web_search", "system.ai.google_drive", "system.ai.google_calendar"])
        let services = Dictionary(settings.servers.map { ($0.name, $0.service) }) { first, _ in first }
        return settings.piServers.keys.filter { !excluded.contains(services[$0] ?? $0) }.sorted()
    }

    func setEnabled(_ enabled: Bool) async {
        await perform { inbox in try inbox.setPaused(!enabled) }
    }

    func edit(_ source: AgentSourceRecord?) {
        error = nil
        guard let source else {
            draft = Draft()
            if let first = servers.first { choose(server: first) } else { chooseCalendar() }
            return
        }
        let senders = (try? JSONDecoder().decode([String].self, from: Data(source.allowedSenders.utf8))) ?? []
        var edited = Draft(
            id: source.id, name: source.name, server: source.server, instructions: source.instructions,
            intervalMinutes: source.intervalMinutes, allowedSenders: senders.joined(separator: ", "), kind: source.kind
        )
        edited.dailyEnabled = source.dailyAt != nil
        edited.leadEnabled = source.leadHours != nil
        edited.leadHours = source.leadHours ?? 24
        if let at = source.dailyAt, let components = AgentInboxService.dailyComponents(at) {
            edited.dailyTime = Calendar.current.date(bySettingHour: components.hour, minute: components.minute, second: 0, of: .now) ?? .now
        }
        draft = edited
    }

    /// A new source's server; the name and what to read follow it until the user changes them.
    func choose(server: String) {
        guard var changed = draft, changed.id == nil else { return }
        let previousName = changed.kind == "calendar" ? L10n.agentCalendarSource : displayName(changed.server)
        if changed.name.isEmpty || changed.name == previousName { changed.name = displayName(server) }
        if changed.instructions.isEmpty || changed.instructions == Self.suggestedInstructions(for: changed.server) {
            changed.instructions = Self.suggestedInstructions(for: server)
        }
        changed.server = server
        changed.kind = "mcp"
        draft = changed
    }

    func chooseCalendar() {
        guard var changed = draft, changed.id == nil else { return }
        if changed.name.isEmpty || changed.name == displayName(changed.server) { changed.name = L10n.agentCalendarSource }
        changed.kind = "calendar"
        changed.server = ""
        draft = changed
    }

    func displayName(_ server: String) -> String {
        server.isEmpty ? "" : AgentMCPServer.displayName(for: services[server] ?? server)
    }

    /// What most people want read from a mail or Slack server, so adding one takes a click.
    static func suggestedInstructions(for server: String) -> String {
        let name = server.lowercased()
        if name.contains("slack") { return L10n.agentAlwaysOnSuggestedSlack }
        if ["gmail", "mail", "outlook"].contains(where: name.contains) { return L10n.agentAlwaysOnSuggestedMail }
        return ""
    }

    func saveDraft() async {
        guard let draft else { return }
        let isCalendar = draft.kind == "calendar"
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
            ?? (isCalendar ? L10n.agentCalendarSource : displayName(draft.server))
        let instructions = draft.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, isCalendar || (!draft.server.isEmpty && !instructions.isEmpty) else {
            error = L10n.agentAlwaysOnRequired
            return
        }
        let senders = draft.allowedSenders.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let existing = sources.first { $0.id == draft.id }
        let now = Date.now
        guard let connectionID = isCalendar ? "" : existing?.connectionID ?? connections[draft.server] else {
            error = L10n.agentAlwaysOnRequired
            return
        }
        var source = AgentSourceRecord(
            id: existing?.id ?? UUID.v7().uuidString, name: name, server: draft.server,
            instructions: instructions, intervalMinutes: draft.intervalMinutes, allowedSenders: String(
                decoding: (try? JSONEncoder().encode(senders)) ?? Data("[]".utf8),
                as: UTF8.self
            ),
            cursor: existing?.cursor, enabled: existing?.enabled ?? true,
            lastIntakeAt: existing?.lastIntakeAt,
            createdAt: existing?.createdAt ?? now, updatedAt: now
        )
        source.connectionID = connectionID
        source.kind = isCalendar ? "calendar" : "mcp"
        if isCalendar {
            let time = Calendar.current.dateComponents([.hour, .minute], from: draft.dailyTime)
            source.dailyAt = draft.dailyEnabled ? String(format: "%02d:%02d", time.hour ?? 8, time.minute ?? 0) : nil
            source.leadHours = draft.leadEnabled ? draft.leadHours : nil
        }
        let saved = source
        await perform { inbox in try inbox.saveSource(saved) }
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
        await perform { inbox in try inbox.deleteSource(id: id) }
        if error == nil { draft = nil }
    }

    private func perform(_ change: @escaping @Sendable (AgentInboxService) throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await PiChatService.shared.updateAlwaysOnSettings(change: change)
            error = nil
        } catch { self.error = error.localizedDescription }
        await refresh()
    }
}
