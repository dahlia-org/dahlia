import Foundation

actor CodexChatService: CodexChatServicing {
    static let shared = CodexChatService()

    private static let developerInstructions = """
    You are a conversational assistant inside Dahlia. Respond directly to the user's message in clear Markdown.
    You may use only the Dahlia meeting tools. Start with query_meetings, then use get_meeting for a selected meeting's summary.
    Call get_meeting_transcript only when the original wording or detail is needed.
    Do not execute commands, access files, use external services, or request permissions.
    """

    private let appServer: CodexAppServerService
    private let workspaceLocator: any CodexChatWorkspaceLocating
    private let mcpExecutableURL: URL?

    init(
        appServer: CodexAppServerService = .shared,
        workspaceLocator: any CodexChatWorkspaceLocating = ApplicationSupportCodexChatWorkspaceLocator(),
        mcpExecutableURL: URL? = nil
    ) {
        self.appServer = appServer
        self.workspaceLocator = workspaceLocator
        self.mcpExecutableURL = mcpExecutableURL
    }

    func models(forceRefresh: Bool = false) async throws -> [CodexModel] {
        try await appServer.models(forceRefresh: forceRefresh)
    }

    func listThreads(cursor: String? = nil, vaultID: UUID) async throws -> CodexChatThreadPage {
        let workspaceURL = try workspaceLocator.workspaceURL(vaultID: vaultID)
        var params: [String: JSONValue] = [
            "archived": .bool(false),
            "cwd": .array([.string(workspaceURL.path)]),
            "limit": .number(25),
            "modelProviders": .array([]),
            "sortDirection": .string("desc"),
            "sortKey": .string("recency_at"),
            "sourceKinds": .array([.string("vscode")]),
        ]
        if let cursor {
            params["cursor"] = .string(cursor)
        }

        let result = try await appServer.request(method: "thread/list", params: .object(params))
        guard let object = result.objectValue,
              let data = object["data"]?.arrayValue
        else {
            throw CodexAppServerError.invalidProtocolResponse
        }

        return try CodexChatThreadPage(
            threads: data.map(Self.parseThreadSummary),
            nextCursor: object["nextCursor"]?.stringValue
        )
    }

    func loadThread(id: String) async throws -> CodexChatThread {
        let result = try await appServer.request(
            method: "thread/read",
            params: .object([
                "includeTurns": .bool(true),
                "threadId": .string(id),
            ])
        )
        guard let thread = result.objectValue?["thread"]?.objectValue else {
            throw CodexAppServerError.invalidProtocolResponse
        }
        return try Self.parseThread(thread, model: nil, reasoningEffort: nil)
    }

    func resumeThread(id: String, vaultID: UUID) async throws -> CodexChatThread {
        let workspaceURL = try workspaceLocator.workspaceURL(vaultID: vaultID)
        let helperURL = try resolvedMCPExecutableURL()
        let config = try await appServer.chatThreadConfiguration(
            reasoningEffort: CodexReasoningEffortOption.defaultValue,
            vaultID: vaultID,
            helperURL: helperURL
        )
        let result = try await appServer.request(
            method: "thread/resume",
            params: .object([
                "approvalPolicy": .string("never"),
                "config": config,
                "cwd": .string(workspaceURL.path),
                "developerInstructions": .string(Self.developerInstructions),
                "sandbox": .string("read-only"),
                "threadId": .string(id),
            ])
        )
        guard let object = result.objectValue,
              let thread = object["thread"]?.objectValue
        else {
            throw CodexAppServerError.invalidProtocolResponse
        }
        return try Self.parseThread(
            thread,
            model: object["model"]?.stringValue,
            reasoningEffort: object["reasoningEffort"]?.stringValue
        )
    }

    func startThread(model: String?, effort: String, vaultID: UUID) async throws -> CodexChatThread {
        let workspaceURL = try workspaceLocator.workspaceURL(vaultID: vaultID)
        let helperURL = try resolvedMCPExecutableURL()
        let availableModels = try await appServer.models()
        let selectedModel = model
            .flatMap { requested in availableModels.first { $0.model == requested } }
            ?? availableModels.first(where: \CodexModel.isDefault)
            ?? availableModels.first
        guard let selectedModel else {
            throw CodexAppServerError.invalidProtocolResponse
        }

        let config = try await appServer.chatThreadConfiguration(
            reasoningEffort: effort,
            vaultID: vaultID,
            helperURL: helperURL
        )
        let result = try await appServer.request(
            method: "thread/start",
            params: .object([
                "approvalPolicy": .string("never"),
                "config": config,
                "cwd": .string(workspaceURL.path),
                "developerInstructions": .string(Self.developerInstructions),
                "ephemeral": .bool(false),
                "model": .string(selectedModel.model),
                "sandbox": .string("read-only"),
            ])
        )
        guard let object = result.objectValue,
              let thread = object["thread"]?.objectValue
        else {
            throw CodexAppServerError.invalidProtocolResponse
        }
        return try Self.parseThread(
            thread,
            model: object["model"]?.stringValue ?? selectedModel.model,
            reasoningEffort: object["reasoningEffort"]?.stringValue ?? effort
        )
    }

    func send(
        threadID: String,
        text: String,
        model: String?,
        effort: String
    ) async throws -> AsyncThrowingStream<CodexChatTurnEvent, any Error> {
        var params: [String: JSONValue] = [
            "effort": .string(effort),
            "input": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(text),
                ]),
            ]),
            "threadId": .string(threadID),
        ]
        if let model = model?.nilIfBlank {
            params["model"] = .string(model)
        }

        let result = try await appServer.request(method: "turn/start", params: .object(params))
        guard let turnID = result.objectValue?["turn"]?.objectValue?["id"]?.stringValue else {
            throw CodexAppServerError.invalidProtocolResponse
        }
        let notifications = await appServer.notifications(threadID: threadID, turnID: turnID)

        return AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.started(turnID: turnID))
                do {
                    for try await notification in notifications {
                        if let event = try Self.parseTurnEvent(notification) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func interrupt(threadID: String, turnID: String) async {
        _ = try? await appServer.request(
            method: "turn/interrupt",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
            ])
        )
    }

    func unsubscribe(threadID: String) async {
        _ = try? await appServer.request(
            method: "thread/unsubscribe",
            params: .object(["threadId": .string(threadID)])
        )
    }

    private func resolvedMCPExecutableURL() throws -> URL {
        if let mcpExecutableURL {
            return mcpExecutableURL
        }
        return try DahliaMCPBundle.executableURL()
    }
}

private extension CodexChatService {
    nonisolated static func parseThreadSummary(_ value: JSONValue) throws -> CodexChatThreadSummary {
        guard let object = value.objectValue,
              let id = object["id"]?.stringValue,
              let updatedAt = object["recencyAt"]?.intValue ?? object["updatedAt"]?.intValue
        else {
            throw CodexAppServerError.invalidProtocolResponse
        }
        let title = object["name"]?.stringValue?.nilIfBlank
            ?? object["preview"]?.stringValue?.nilIfBlank
            ?? ""
        return CodexChatThreadSummary(
            id: id,
            title: title,
            updatedAt: Date(timeIntervalSince1970: TimeInterval(updatedAt))
        )
    }

    nonisolated static func parseThread(
        _ object: [String: JSONValue],
        model: String?,
        reasoningEffort: String?
    ) throws -> CodexChatThread {
        guard let id = object["id"]?.stringValue,
              let turns = object["turns"]?.arrayValue
        else {
            throw CodexAppServerError.invalidProtocolResponse
        }
        let title = object["name"]?.stringValue?.nilIfBlank
            ?? object["preview"]?.stringValue?.nilIfBlank
            ?? ""
        return CodexChatThread(
            id: id,
            title: title,
            messages: turns.flatMap(parseMessages),
            model: model,
            reasoningEffort: reasoningEffort
        )
    }

    nonisolated static func parseMessages(_ turn: JSONValue) -> [CodexChatMessage] {
        guard let items = turn.objectValue?["items"]?.arrayValue else { return [] }
        return items.compactMap { item in
            guard let object = item.objectValue,
                  let id = object["id"]?.stringValue,
                  let type = object["type"]?.stringValue
            else { return nil }

            switch type {
            case "userMessage":
                let text = object["content"]?.arrayValue?
                    .compactMap { input -> String? in
                        guard input.objectValue?["type"]?.stringValue == "text" else { return nil }
                        return input.objectValue?["text"]?.stringValue
                    }
                    .joined(separator: "\n")
                guard let text = text?.nilIfBlank else { return nil }
                return CodexChatMessage(id: id, role: .user, text: text)
            case "agentMessage":
                guard let text = object["text"]?.stringValue?.nilIfBlank else { return nil }
                return CodexChatMessage(id: id, role: .assistant, text: text)
            default:
                return nil
            }
        }
    }

    nonisolated static func parseTurnEvent(_ value: JSONValue) throws -> CodexChatTurnEvent? {
        guard let object = value.objectValue,
              let method = object["method"]?.stringValue,
              let params = object["params"]?.objectValue
        else {
            throw CodexAppServerError.invalidProtocolResponse
        }

        switch method {
        case "item/agentMessage/delta":
            return try parseDelta(params)
        case "item/completed":
            return try parseCompletedItem(params)
        case "turn/completed":
            return try parseTurnCompletion(params)
        default:
            return nil
        }
    }

    nonisolated static func parseDelta(_ params: [String: JSONValue]) throws -> CodexChatTurnEvent {
        guard let itemID = params["itemId"]?.stringValue,
              let delta = params["delta"]?.stringValue
        else {
            throw CodexAppServerError.invalidProtocolResponse
        }
        return .delta(itemID: itemID, text: delta)
    }

    nonisolated static func parseCompletedItem(_ params: [String: JSONValue]) throws -> CodexChatTurnEvent? {
        guard let item = params["item"]?.objectValue else {
            throw CodexAppServerError.invalidProtocolResponse
        }
        guard item["type"]?.stringValue == "agentMessage" else { return nil }
        guard let itemID = item["id"]?.stringValue,
              let text = item["text"]?.stringValue
        else {
            throw CodexAppServerError.invalidProtocolResponse
        }
        return .completed(itemID: itemID, text: text)
    }

    nonisolated static func parseTurnCompletion(_ params: [String: JSONValue]) throws -> CodexChatTurnEvent {
        guard let turn = params["turn"]?.objectValue,
              let status = turn["status"]?.stringValue
        else {
            throw CodexAppServerError.invalidProtocolResponse
        }
        switch status {
        case "completed":
            return .completed(itemID: nil, text: nil)
        case "interrupted":
            return .interrupted
        case "failed":
            let error = turn["error"]?.objectValue
            if isAuthenticationError(error) {
                throw CodexAppServerError.notLoggedIn
            }
            return .failed(message: error?["message"]?.stringValue)
        default:
            throw CodexAppServerError.invalidProtocolResponse
        }
    }

    nonisolated static func isAuthenticationError(_ error: [String: JSONValue]?) -> Bool {
        guard let error else { return false }
        let info = error["codexErrorInfo"]?.stringValue?.lowercased()
        let message = error["message"]?.stringValue?.lowercased()
        return info == "unauthorized"
            || info == "invalid_api_key"
            || message?.contains("unauthorized") == true
            || message?.contains("not logged in") == true
    }
}
