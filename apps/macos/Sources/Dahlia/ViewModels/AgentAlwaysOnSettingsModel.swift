import Foundation
import Observation

/// The Always-on tab: the inbox of Items, the request field, the account's switch, guidance and work settings, its
/// Sources, and the events intake recorded. The database is read off MainActor through the inbox service.
@MainActor
@Observable
final class AgentAlwaysOnSettingsModel {
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

    var sources: [AgentSourceRecord] = []
    var events: [AgentEventRecord] = []
    var servers: [String] = []
    var connections: [String: String] = [:]
    var paused = false
    var draft: Draft?
    var items: [AgentItemRecord] = []
    /// Each Task's Thread, by Task, for the Items that belong to one.
    var taskThreads: [String: String] = [:]
    /// Typed answers to questions, by Item.
    var answers: [String: String] = [:]
    var request = ""
    var guidance = ""
    var workServers: Set<String> = []
    var webSearch = false
    var error: String?
    var isBusy = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guidance = AgentBotSettings.guidance(for: AppAccount.key, defaults: defaults)
        workServers = Set(AgentBotSettings.workServers(for: AppAccount.key, defaults: defaults))
        webSearch = AgentBotSettings.webSearch(for: AppAccount.key, defaults: defaults)
    }

    private let defaults: UserDefaults

    func saveGuidance() {
        guidance = String(guidance.prefix(AgentBotSettings.guidanceLimit))
        defaults.set(guidance, forKey: AgentBotSettings.guidanceKey(for: AppAccount.key))
    }

    func setWorkServer(_ server: String, allowed: Bool) {
        guard let id = connections[server] else { return }
        if allowed { workServers.insert(id) } else { workServers.remove(id) }
        defaults.set(workServers.sorted(), forKey: AgentBotSettings.workServersKey(for: AppAccount.key))
    }

    func isWorkServerAllowed(_ server: String) -> Bool {
        connections[server].map(workServers.contains) ?? false
    }

    func setWebSearch(_ enabled: Bool) {
        webSearch = enabled
        defaults.set(enabled, forKey: AgentBotSettings.webSearchKey(for: AppAccount.key))
    }

    /// Opens the user's conversation with the secretary, making it the first time.
    func openHome() async {
        do {
            let id = try await PiChatService.shared.botHomeThread()
            NotificationCenter.default.post(name: AgentLearningSettings.openThread, object: id)
        } catch { self.error = error.localizedDescription }
    }

    func sendRequest() async {
        let text = request
        await perform { inbox, key in try inbox.request(text, account: key) }
        if error == nil { request = "" }
    }

    /// Answers the revision on screen; when the Item changed meanwhile, nothing is applied and the list reloads.
    func answer(_ item: AgentItemRecord, with text: String) async {
        await perform { inbox, key in _ = try inbox.answer(itemID: item.id, revision: item.revision, answer: text, account: key) }
        answers[item.id] = nil
    }

    func dismiss(_ item: AgentItemRecord) async {
        await perform { inbox, key in _ = try inbox.dismiss(itemID: item.id, revision: item.revision, account: key) }
    }

    func refresh() async {
        do {
            let loaded = try await PiChatService.shared.loadAlwaysOnSettings(account: AppAccount.key)
            (sources, events, paused) = loaded
            (items, taskThreads) = try await PiChatService.shared.loadBotInbox(account: AppAccount.key)
            // Only servers with a sign-in reach mcp.json, so only they can be read.
            let settings = AgentMCPSettings.load()
            servers = settings.piServers.keys.sorted()
            connections = Dictionary(uniqueKeysWithValues: servers.compactMap { name in settings.connectionID(for: name).map { (name, $0) } })
        } catch { self.error = error.localizedDescription }
    }

    func setEnabled(_ enabled: Bool) async {
        await perform { inbox, key in try inbox.setPaused(!enabled, account: key) }
    }

    func edit(_ source: AgentSourceRecord?) {
        error = nil
        guard let source else {
            draft = Draft(server: servers.first ?? "")
            return
        }
        let senders = (try? JSONDecoder().decode([String].self, from: Data(source.allowedSenders.utf8))) ?? []
        draft = Draft(
            id: source.id, name: source.name, server: source.server, instructions: source.instructions,
            intervalMinutes: source.intervalMinutes, sieve: source.sieve, allowedSenders: senders.joined(separator: ", ")
        )
    }

    func saveDraft() async {
        guard let draft else { return }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
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

    func clearGap(_ source: AgentSourceRecord) async {
        await perform { inbox, key in try inbox.clearGap(sourceID: source.id, account: key) }
    }

    func delete(_ source: AgentSourceRecord) async {
        await perform { inbox, key in try inbox.deleteSource(id: source.id, account: key) }
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
