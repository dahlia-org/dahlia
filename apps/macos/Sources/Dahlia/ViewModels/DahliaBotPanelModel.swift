import AppKit
import Foundation
import Observation

/// Super Agent's side panel and its event source editor: the Items that need the user, its Tasks, the Sources intake
/// reads, `SOUL.md`, and the events intake recorded. The database and the home folder are read off MainActor through
/// `PiChatService`.
@MainActor
@Observable
final class DahliaBotPanelModel {
    struct Draft: Equatable {
        var id: String?
        var name = ""
        var server = ""
        var instructions = ""
        var intervalMinutes = 15
        var sieve = "explicit"
        var allowedSenders = ""
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
    var soul = ""
    /// The text being edited, while the user edits `SOUL.md`.
    var soulDraft: String?
    var error: String?
    var isBusy = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private let defaults: UserDefaults

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
        guard let last = finishedTasks.last else { return }
        do {
            let page = try await PiChatService.shared.loadBotTasks(finishedBefore: last.updatedAt, limit: Self.taskPage)
            finishedTasks += page.finished
            hasMoreFinishedTasks = page.finished.count == Self.taskPage
        } catch { self.error = error.localizedDescription }
    }

    /// Answers the revision on screen; when the Item changed meanwhile, nothing is applied and the list reloads.
    func answer(_ item: AgentItemRecord, with text: String) async {
        await perform { inbox, key in _ = try inbox.answer(itemID: item.id, revision: item.revision, answer: text, account: key) }
        answers[item.id] = nil
    }

    /// The user ends a Task; its thread stays as it is.
    func finish(_ task: AgentTaskRecord) async {
        guard let thread = task.threadID else { return }
        await perform { inbox, key in try inbox.finishTask(threadID: thread, status: "done", account: key) }
    }

    func dismiss(_ item: AgentItemRecord) async {
        await perform { inbox, key in _ = try inbox.dismiss(itemID: item.id, revision: item.revision, account: key) }
    }

    func refresh() async {
        do {
            let loaded = try await PiChatService.shared.loadAlwaysOnSettings(account: AppAccount.key)
            (sources, events, paused) = loaded
            (items, taskThreads) = try await PiChatService.shared.loadBotInbox(account: AppAccount.key)
            // A refresh keeps the finished Tasks the user paged through.
            let limit = max(Self.taskPage, finishedTasks.count)
            let tasks = try await PiChatService.shared.loadBotTasks(finishedBefore: nil, limit: limit)
            activeTasks = tasks.active
            finishedTasks = tasks.finished
            hasMoreFinishedTasks = tasks.finished.count == limit
            if soulDraft == nil { soul = try await PiChatService.shared.loadBotSoul() }
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
        await perform { inbox, key in try inbox.setPaused(!enabled, account: key) }
    }

    func edit(_ source: AgentSourceRecord?) {
        error = nil
        guard let source else {
            draft = Draft()
            if let first = servers.first { choose(server: first) }
            return
        }
        let senders = (try? JSONDecoder().decode([String].self, from: Data(source.allowedSenders.utf8))) ?? []
        draft = Draft(
            id: source.id, name: source.name, server: source.server, instructions: source.instructions,
            intervalMinutes: source.intervalMinutes, sieve: source.sieve, allowedSenders: senders.joined(separator: ", ")
        )
    }

    /// A new source's server; the name and what to read follow it until the user changes them.
    func choose(server: String) {
        guard var changed = draft, changed.id == nil else { return }
        if changed.name.isEmpty || changed.name == displayName(changed.server) { changed.name = displayName(server) }
        if changed.instructions.isEmpty || changed.instructions == Self.suggestedInstructions(for: changed.server) {
            changed.instructions = Self.suggestedInstructions(for: server)
        }
        changed.server = server
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
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank ?? displayName(draft.server)
        let instructions = draft.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !draft.server.isEmpty, !instructions.isEmpty else {
            error = L10n.agentAlwaysOnRequired
            return
        }
        let senders = draft.allowedSenders.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let existing = sources.first { $0.id == draft.id }
        let now = Date.now
        guard let connectionID = existing?.connectionID ?? connections[draft.server] else {
            error = L10n.agentAlwaysOnRequired
            return
        }
        var source = AgentSourceRecord(
            id: existing?.id ?? UUID.v7().uuidString, accountID: AppAccount.key, name: name, server: draft.server,
            instructions: instructions, intervalMinutes: draft.intervalMinutes, sieve: draft.sieve,
            allowedSenders: String(decoding: (try? JSONEncoder().encode(senders)) ?? Data("[]".utf8), as: UTF8.self),
            cursor: existing?.cursor, enabled: existing?.enabled ?? true,
            gapDetectedAt: existing?.gapDetectedAt, lastIntakeAt: existing?.lastIntakeAt,
            createdAt: existing?.createdAt ?? now, updatedAt: now
        )
        source.connectionID = connectionID
        let saved = source
        await perform { inbox, _ in try inbox.saveSource(saved) }
        if error == nil { self.draft = nil }
    }

    func setEnabled(_ source: AgentSourceRecord, enabled: Bool) async {
        var changed = source
        changed.enabled = enabled
        changed.updatedAt = .now
        let saved = changed
        await perform { inbox, _ in try inbox.saveSource(saved) }
    }

    func setInterval(_ source: AgentSourceRecord, minutes: Int) async {
        guard minutes != source.intervalMinutes else { return }
        var changed = source
        changed.intervalMinutes = minutes
        changed.updatedAt = .now
        let saved = changed
        await perform { inbox, _ in try inbox.saveSource(saved) }
    }

    func clearGap(_ source: AgentSourceRecord) async {
        await perform { inbox, key in try inbox.clearGap(sourceID: source.id, account: key) }
    }

    func deleteDraft() async {
        guard let id = draft?.id else { return }
        await perform { inbox, key in try inbox.deleteSource(id: id, account: key) }
        if error == nil { draft = nil }
    }

    private func perform(_ change: @escaping @Sendable (AgentInboxService, String) throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await PiChatService.shared.updateAlwaysOnSettings(account: AppAccount.key, change: change)
            error = nil
        } catch { self.error = error.localizedDescription }
        await refresh()
    }
}
