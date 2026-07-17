import Foundation
@testable import Dahlia

actor TestCodexChatAppServerTransport: CodexAppServerTransport {
    enum TurnOutcome {
        case completed
        case interrupted
        case failed
        case disconnected
    }

    private let turnOutcome: TurnOutcome
    private var responses: [Data] = []
    private var sentMessages: [JSONValue] = []
    private var receiveContinuation: CheckedContinuation<Data?, Never>?
    private var isClosed = false

    init(turnOutcome: TurnOutcome = .completed) {
        self.turnOutcome = turnOutcome
    }

    func sendLine(_ data: Data) throws {
        let message = try JSONDecoder().decode(JSONValue.self, from: data)
        sentMessages.append(message)
        guard let object = message.objectValue,
              let requestID = object["id"]?.intValue,
              let method = object["method"]?.stringValue
        else { return }

        if handleConnectionRequest(method: method, requestID: requestID) {
            return
        }
        if handleThreadRequest(method: method, requestID: requestID) {
            return
        }
        if method == "turn/start" {
            enqueueTurn(requestID: requestID)
        } else {
            enqueueResponse(requestID, result: .object([:]))
        }
    }

    private func handleConnectionRequest(method: String, requestID: Int) -> Bool {
        switch method {
        case "initialize":
            enqueueResponse(requestID, result: .object([
                "userAgent": .string("test"),
                "platformFamily": .string("unix"),
                "platformOs": .string("macos"),
            ]))
        case "account/read":
            enqueueResponse(requestID, result: .object([
                "account": .object([
                    "type": .string("chatgpt"),
                    "email": .string("test@example.com"),
                    "planType": .string("plus"),
                ]),
                "requiresOpenaiAuth": .bool(true),
            ]))
        case "model/list":
            enqueueResponse(requestID, result: TestCodexChatFixtures.modelList)
        case "config/read":
            enqueueResponse(requestID, result: .object([
                "config": .object([
                    "mcp_servers": .object([
                        "docs": .object(["url": .string("https://example.com/mcp")]),
                    ]),
                ]),
            ]))
        default:
            return false
        }
        return true
    }

    private func handleThreadRequest(method: String, requestID: Int) -> Bool {
        switch method {
        case "thread/list":
            enqueueResponse(requestID, result: .object([
                "data": .array([
                    .object([
                        "id": .string("thread-history"),
                        "preview": .string("Previous chat"),
                        "recencyAt": .number(1_700_000_000),
                    ]),
                ]),
                "nextCursor": .string("next-page"),
            ]))
        case "thread/read":
            enqueueResponse(requestID, result: .object([
                "thread": TestCodexChatFixtures.chatThread(id: "thread-history"),
            ]))
        case "thread/resume":
            enqueueResponse(requestID, result: .object([
                "thread": TestCodexChatFixtures.chatThread(id: "thread-history"),
                "model": .string("default-model"),
                "reasoningEffort": .string("high"),
            ]))
        case "thread/start":
            enqueueResponse(requestID, result: .object([
                "thread": .object([
                    "id": .string("thread-1"),
                    "preview": .string(""),
                    "turns": .array([]),
                ]),
                "model": .string("default-model"),
                "reasoningEffort": .string("medium"),
            ]))
        case "turn/interrupt", "thread/unsubscribe":
            enqueueResponse(requestID, result: .object([:]))
        default:
            return false
        }
        return true
    }

    func receiveLine() async -> Data? {
        if !responses.isEmpty {
            return responses.removeFirst()
        }
        guard !isClosed else { return nil }
        return await withCheckedContinuation { receiveContinuation = $0 }
    }

    func close() async {
        isClosed = true
        receiveContinuation?.resume(returning: nil)
        receiveContinuation = nil
    }

    func messages() -> [JSONValue] {
        sentMessages
    }

    func simulateDisconnect() async {
        await close()
    }

    private func enqueueTurn(requestID: Int) {
        switch turnOutcome {
        case .completed:
            enqueueCompletedTurn(requestID: requestID)
        case .interrupted:
            enqueueResponse(requestID, result: inProgressTurn)
            enqueueTurnCompletion(status: "interrupted")
        case .failed:
            enqueueResponse(requestID, result: inProgressTurn)
            enqueueTurnCompletion(
                status: "failed",
                error: .object(["message": .string("Model unavailable")])
            )
        case .disconnected:
            enqueueResponse(requestID, result: inProgressTurn)
        }
    }

    private func enqueueCompletedTurn(requestID: Int) {
        enqueue(.object([
            "method": .string("item/reasoning/summaryTextDelta"),
            "params": turnParams([
                "itemId": .string("reasoning-1"),
                "summaryIndex": .number(0),
                "delta": .string("Checked the request"),
            ]),
        ]))
        enqueue(.object([
            "method": .string("item/agentMessage/delta"),
            "params": turnParams([
                "itemId": .string("item-1"),
                "delta": .string("Hel"),
            ]),
        ]))
        enqueue(.object([
            "method": .string("item/agentMessage/delta"),
            "params": turnParams([
                "itemId": .string("item-1"),
                "delta": .string("lo"),
            ]),
        ]))
        enqueueResponse(requestID, result: inProgressTurn)
        enqueue(.object([
            "method": .string("item/completed"),
            "params": turnParams([
                "item": .object([
                    "type": .string("commandExecution"),
                ]),
            ]),
        ]))
        enqueue(.object([
            "method": .string("item/completed"),
            "params": turnParams([
                "item": .object([
                    "id": .string("reasoning-1"),
                    "type": .string("reasoning"),
                    "summary": .array([
                        .object([
                            "type": .string("summary_text"),
                            "text": .string("Checked the request"),
                        ]),
                    ]),
                    "content": .array([]),
                ]),
            ]),
        ]))
        enqueue(.object([
            "method": .string("item/completed"),
            "params": turnParams([
                "item": .object([
                    "id": .string("item-1"),
                    "type": .string("agentMessage"),
                    "text": .string("Hello"),
                ]),
            ]),
        ]))
        enqueueTurnCompletion(status: "completed")
    }

    private func enqueueTurnCompletion(status: String, error: JSONValue? = nil) {
        var turn: [String: JSONValue] = [
            "id": .string("turn-1"),
            "status": .string(status),
        ]
        if let error {
            turn["error"] = error
        }
        enqueue(.object([
            "method": .string("turn/completed"),
            "params": .object([
                "threadId": .string("thread-1"),
                "turn": .object(turn),
            ]),
        ]))
    }

    private func turnParams(_ additional: [String: JSONValue]) -> JSONValue {
        .object(additional.merging([
            "threadId": .string("thread-1"),
            "turnId": .string("turn-1"),
        ]) { value, _ in value })
    }

    private func enqueueResponse(_ id: Int, result: JSONValue) {
        enqueue(.object([
            "id": .number(Double(id)),
            "result": result,
        ]))
    }

    private func enqueue(_ value: JSONValue) {
        let data = (try? JSONEncoder().encode(value)) ?? Data()
        if let continuation = receiveContinuation {
            receiveContinuation = nil
            continuation.resume(returning: data)
        } else {
            responses.append(data)
        }
    }

    private var inProgressTurn: JSONValue {
        .object([
            "turn": .object([
                "id": .string("turn-1"),
                "status": .string("inProgress"),
            ]),
        ])
    }

}
