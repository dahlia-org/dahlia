import DahliaRuntimeSupport
import Foundation

/// Databricks-hosted Omnigent (`https://<workspace>/api/2.0/omnigent`), called with the Databricks account's own sign-in.
/// Chat reaches it through the `omni_*` tools, and the Chat sidebar lists its sessions.
enum OmnigentService {
    struct Session: Decodable, Identifiable, Equatable, Sendable {
        let id: String
        let title: String?
        let status: String?
    }

    struct Message: Identifiable, Equatable, Sendable {
        let id: String
        let role: String
        let text: String
    }

    struct Snapshot: Sendable {
        let title: String?
        let status: String?
        let messages: [Message]
    }

    struct RequestError: LocalizedError {
        let status: Int
        let body: String
        var errorDescription: String? { "Omnigent returned HTTP \(status): \(body)" }
    }

    nonisolated static func enabledKey(_ account: String) -> String { "omnigentEnabled.\(account)" }

    /// The Databricks workspace to call, when the account is a Databricks account that turned Omnigent on (it is off by default).
    nonisolated static func connectionID(for provider: CodexRuntimeProvider, defaults: UserDefaults = .standard) -> UUID? {
        guard case let .databricks(connectionID) = provider, defaults.bool(forKey: enabledKey(provider.accountKey)) else { return nil }
        return connectionID
    }

    static func sessions(connectionID: UUID) async throws -> [Session] {
        struct Page: Decodable { let data: [Session] }
        let data = try await request(connectionID, path: "v1/sessions", query: ["limit": "30", "sort_by": "updated_at"])
        return try JSONDecoder().decode(Page.self, from: data).data
    }

    /// The session in the workspace's Omnigent web UI.
    nonisolated static func webURL(host: String, workspaceID: String?, sessionID: String) -> URL? {
        guard var components = URLComponents(string: host) else { return nil }
        components.path = "/omnigent/c/\(sessionID)"
        components.queryItems = workspaceID.map { [URLQueryItem(name: "o", value: $0)] }
        return components.url
    }

    /// Session IDs come from the model and become URL path segments.
    nonisolated static func isValidSessionID(_ id: String) -> Bool {
        (1 ... 128).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    nonisolated static func startBody(_ args: [String: JSONValue]) throws -> JSONValue {
        guard let agentID = args["agent_id"]?.stringValue?.nilIfBlank, let input = args["input"]?.stringValue?.nilIfBlank else {
            throw PiRuntimeError.rpcError(code: nil, message: "agent_id and input are required")
        }
        var body: [String: JSONValue] = [
            "agent_id": .string(agentID),
            // The server provisions a sandbox for the session.
            "host_type": .string("managed"),
            "initial_items": .array([.object([
                "type": .string("message"),
                "data": .object([
                    "role": .string("user"),
                    "content": .array([.object(["type": .string("input_text"), "text": .string(input)])]),
                ]),
            ])]),
        ]
        if let title = args["title"]?.stringValue?.nilIfBlank { body["title"] = .string(String(title.prefix(256))) }
        if let repository = args["repository"]?.stringValue?.nilIfBlank { body["workspace"] = .string(repository) }
        return .object(body)
    }

    /// A message item's text; tool calls and resource events are not messages.
    nonisolated static func message(_ item: JSONValue) -> Message? {
        guard let item = item.objectValue, item["type"]?.stringValue == "message", let id = item["id"]?.stringValue else { return nil }
        let text = (item["content"]?.arrayValue ?? []).compactMap { $0.objectValue?["text"]?.stringValue }.joined(separator: "\n")
        return Message(id: id, role: item["role"]?.stringValue ?? "assistant", text: text)
    }

    /// The messages of an items page read newest first, returned oldest first.
    nonisolated static func messages(_ items: JSONValue) -> [Message] {
        (items.objectValue?["data"]?.arrayValue ?? []).reversed().compactMap(message)
    }

    /// The session's title, status, and latest messages.
    static func snapshot(connectionID: UUID, sessionID: String) async throws -> Snapshot {
        guard isValidSessionID(sessionID) else { throw PiRuntimeError.rpcError(code: nil, message: "Invalid session_id") }
        async let session = json(connectionID, path: "v1/sessions/\(sessionID)")
        // shortcut: only the newest 200 items (messages, tool calls, and events); add paging when long sessions need older messages.
        async let items = json(connectionID, path: "v1/sessions/\(sessionID)/items", query: ["limit": "200", "order": "desc"])
        let object = try await session.objectValue ?? [:]
        return try await Snapshot(title: object["title"]?.stringValue, status: object["status"]?.stringValue, messages: messages(items))
    }

    /// The session's live SSE events (`data:` payloads), until the server ends the stream. It replays nothing:
    /// the server sends a heartbeat once subscribed, after which a snapshot misses no event.
    static func events(connectionID: UUID, sessionID: String) async throws -> AsyncThrowingStream<JSONValue, any Error> {
        guard isValidSessionID(sessionID) else { throw PiRuntimeError.rpcError(code: nil, message: "Invalid session_id") }
        // The server sends a heartbeat every 15 seconds, so a quiet minute means a dead connection.
        var request = try await urlRequest(connectionID, path: "v1/sessions/\(sessionID)/stream", timeout: 60)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw URLError(.badServerResponse) }
        guard (200 ..< 300).contains(status) else { throw RequestError(status: status, body: "") }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines where line.hasPrefix("data:") {
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        if let event = try? JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8)) { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func tool(_ method: String, arguments args: [String: JSONValue], connectionID: UUID) async throws -> JSONValue {
        let connection = try await DatabricksOAuthService.shared.connection(id: connectionID)
        func url(_ id: String) -> JSONValue {
            webURL(host: connection.host, workspaceID: connection.workspaceID, sessionID: id).map { .string($0.absoluteString) } ?? .null
        }
        switch method {
        case "omni_list_agents":
            let page = try await json(connectionID, path: "v1/agents", query: ["limit": "100"])
            return .object(["agents": .array(rows(page, keys: ["id", "name", "description", "harness"]))])
        case "omni_list_sessions":
            var query = ["limit": String(min(max(args["limit"]?.intValue ?? 20, 1), 100)), "sort_by": "updated_at"]
            query["search_query"] = args["query"]?.stringValue?.nilIfBlank.map { String($0.prefix(1024)) }
            query["after"] = args["cursor"]?.stringValue?.nilIfBlank
            let page = try await json(connectionID, path: "v1/sessions", query: query)
            let hasMore = page.objectValue?["has_more"]?.boolValue == true
            return .object([
                "sessions": .array(rows(page, keys: ["id", "title", "status", "agent_name", "workspace", "updated_at"])),
                "next_cursor": hasMore ? page.objectValue?["last_id"] ?? .null : .null,
            ])
        case "omni_create_session":
            let session = try await json(connectionID, method: "POST", path: "v1/sessions", body: startBody(args))
            guard let id = session.objectValue?["id"]?.stringValue else { throw PiRuntimeError.invalidProtocolResponse }
            return .object(["session_id": .string(id), "status": session.objectValue?["status"] ?? .null, "url": url(id)])
        case "omni_get_session":
            guard let id = args["session_id"]?.stringValue, isValidSessionID(id) else {
                throw PiRuntimeError.rpcError(code: nil, message: "Invalid session_id")
            }
            let limit = String(min(max(args["limit"]?.intValue ?? 10, 1), 50))
            let session = try await json(connectionID, path: "v1/sessions/\(id)").objectValue ?? [:]
            // Items include tool calls and resource events; read a wider page to find `limit` messages.
            let items = try await json(connectionID, path: "v1/sessions/\(id)/items", query: ["limit": "200", "order": "desc"])
            return .object([
                "session_id": .string(id),
                "title": session["title"] ?? .null,
                "status": session["status"] ?? .null,
                "last_task_error": session["last_task_error"] ?? .null,
                "pending_approvals": .number(Double(session["pending_elicitations"]?.arrayValue?.count ?? 0)),
                "url": url(id),
                "messages": .array(messages(items).suffix(Int(limit) ?? 10).map {
                    .object(["role": .string($0.role), "text": .string(String($0.text.prefix(8000)))])
                }),
            ])
        default:
            throw PiRuntimeError.invalidProtocolResponse
        }
    }

    private static func rows(_ page: JSONValue, keys: [String]) -> [JSONValue] {
        (page.objectValue?["data"]?.arrayValue ?? []).map { row in
            .object(Dictionary(uniqueKeysWithValues: keys.map { ($0, row.objectValue?[$0] ?? .null) }))
        }
    }

    private static func json(
        _ connectionID: UUID, method: String = "GET", path: String, query: [String: String] = [:], body: JSONValue? = nil
    ) async throws -> JSONValue {
        try await JSONDecoder().decode(JSONValue.self, from: request(connectionID, method: method, path: path, query: query, body: body))
    }

    private static func request(
        _ connectionID: UUID, method: String = "GET", path: String, query: [String: String] = [:], body: JSONValue? = nil
    ) async throws -> Data {
        let request = try await urlRequest(connectionID, method: method, path: path, query: query, body: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw URLError(.badServerResponse) }
        guard (200 ..< 300).contains(status) else { throw RequestError(status: status, body: String(decoding: data.prefix(500), as: UTF8.self)) }
        return data
    }

    private static func urlRequest(
        _ connectionID: UUID,
        method: String = "GET",
        path: String,
        query: [String: String] = [:],
        body: JSONValue? = nil,
        timeout: TimeInterval = 30
    ) async throws -> URLRequest {
        let service = DatabricksOAuthService.shared
        let connection = try await service.connection(id: connectionID)
        // Chat and the sidebar never open a browser sign-in; an expired sign-in is repaired in Settings.
        let token = try await service.accessToken(connectionID: connectionID, interactive: false)
        let base = try service.normalizedWorkspaceURL(connection.host).appending(path: "api/2.0/omnigent/\(path)")
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { throw URLError(.badURL) }
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let workspaceID = connection.workspaceID { request.setValue(workspaceID, forHTTPHeaderField: "X-Databricks-Org-Id") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        return request
    }
}

extension PiChatService {
    nonisolated static let readOmnigentTools = ["omni_list_agents", "omni_list_sessions", "omni_get_session"]

    func omnigentTool(_ method: String, payload: JSONValue, threadID: String, processID: UUID) async throws -> JSONValue {
        guard let session = sessions[threadID], session.processID == processID, let turn = session.turn,
              session.profile == .interactive else { throw CancellationError() }
        // Read at each call: turning Omnigent off in Settings stops a process that still lists the tools.
        guard let connectionID = omnigentConnection(session.provider) else {
            throw PiRuntimeError.rpcError(code: nil, message: "Omnigent is turned off for this account")
        }
        if method == "omni_create_session" {
            if let input = payload.objectValue?["input"]?.stringValue, input.count > 32000 {
                throw PiRuntimeError.rpcError(code: nil, message: "Input exceeds 32000 characters")
            }
            let thread = try history().thread(id: threadID, accountID: session.provider.accountKey)
            // Work done for another thread never delegates further, as with `dah_thread_start`.
            guard thread.parentThreadID == nil, turn.run.requestedByThreadID == nil else {
                throw PiRuntimeError.rpcError(code: nil, message: "Work requested by another thread cannot start Omnigent sessions")
            }
        }
        return try await OmnigentService.tool(method, arguments: payload.objectValue ?? [:], connectionID: connectionID)
    }
}
