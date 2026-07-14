import Foundation
@testable import Dahlia

actor TestCodexAppServerTransport: CodexAppServerTransport {
    enum Mode: Equatable {
        case models
        case blockInitialize
        case blockFirstModelList
        case blockRequests
        case outOfOrder
        case serverRequests
        case generationCompletes
        case generationBlocks
        case generationFailsUnauthorized
        case generationFailsMessageOnlyUnauthorized
        case signedOut
        case loginCompletes
        case loginBlocks
        case textOnlyGenerationCompletes
        case blockClose
        case invalidInitializeResponse
    }

    private let mode: Mode
    private var responses: [Data] = []
    private var sentMessages: [JSONValue] = []
    private var receiveContinuation: CheckedContinuation<Data?, Never>?
    private var methodWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var modelListCount = 0
    private var heldRequestID: Int?
    private var closeContinuation: CheckedContinuation<Void, Never>?
    private var didStartClosing = false
    private var isAuthenticated: Bool
    private(set) var isClosed = false

    init(mode: Mode) {
        self.mode = mode
        isAuthenticated = mode != .signedOut && mode != .loginCompletes && mode != .loginBlocks
    }

    func sendLine(_ data: Data) throws {
        let message = try JSONDecoder().decode(JSONValue.self, from: data)
        sentMessages.append(message)
        if let responseKey = responseKey(message.objectValue?["id"]) {
            resumeMethodWaiters(responseKey)
        }
        guard let object = message.objectValue,
              let method = object["method"]?.stringValue
        else { return }
        resumeMethodWaiters(method)

        guard let requestID = object["id"]?.intValue else { return }
        enqueueResponse(to: requestID, method: method)
    }

    private func enqueueResponse(to requestID: Int, method: String) {
        switch method {
        case "initialize":
            enqueueInitializeResponse(requestID: requestID)
        case "model/list":
            enqueueModelListResponse(requestID: requestID)
        case "account/read":
            enqueueAccountReadResponse(requestID: requestID)
        case "account/login/start":
            enqueueLoginStartResponse(requestID: requestID)
        case "account/login/cancel":
            enqueue(response(id: requestID, result: .object([:])))
            enqueue(jsonValue: .object([
                "method": .string("account/login/completed"),
                "params": .object([
                    "error": .string("Login cancelled"),
                    "loginId": .string("login-1"),
                    "success": .bool(false),
                ]),
            ]))
        case "account/logout":
            isAuthenticated = false
            enqueue(response(id: requestID, result: .object([:])))
            enqueue(jsonValue: .object([
                "method": .string("account/updated"),
                "params": .object([
                    "authMode": .null,
                    "planType": .null,
                ]),
            ]))
        case "config/read":
            enqueue(response(id: requestID, result: .object([
                "config": .object([
                    "mcp_servers": .object([
                        "docs": .object(["url": .string("https://example.com/mcp")]),
                        "local.server": .object(["command": .string("example-mcp")]),
                    ]),
                ]),
                "origins": .object([:]),
                "layers": .null,
            ])))
        case "thread/start":
            enqueue(response(id: requestID, result: .object([
                "thread": .object(["id": .string("thread-1")]),
            ])))
        case "turn/start":
            enqueueTurnStartResponse(requestID: requestID)
        case "turn/interrupt", "thread/unsubscribe":
            enqueue(response(id: requestID, result: .object([:])))
        default:
            enqueueTestResponse(to: requestID, method: method)
        }
    }

    private func enqueueAccountReadResponse(requestID: Int) {
        let account: JSONValue = if isAuthenticated {
            .object([
                "type": .string("chatgpt"),
                "email": .string("test@example.com"),
                "planType": .string("plus"),
            ])
        } else {
            .null
        }
        enqueue(response(id: requestID, result: .object([
            "account": account,
            "requiresOpenaiAuth": .bool(true),
        ])))
    }

    private func enqueueLoginStartResponse(requestID: Int) {
        enqueue(response(id: requestID, result: .object([
            "type": .string("chatgpt"),
            "loginId": .string("login-1"),
            "authUrl": .string("https://chatgpt.com/auth/test"),
        ])))
        guard mode == .loginCompletes else { return }
        isAuthenticated = true
        enqueue(jsonValue: .object([
            "method": .string("account/login/completed"),
            "params": .object([
                "error": .null,
                "loginId": .string("login-1"),
                "success": .bool(true),
            ]),
        ]))
        enqueue(jsonValue: .object([
            "method": .string("account/updated"),
            "params": .object([
                "authMode": .string("chatgpt"),
                "planType": .string("plus"),
            ]),
        ]))
    }

    private func enqueueInitializeResponse(requestID: Int) {
        if mode == .blockInitialize {
            return
        } else if mode == .invalidInitializeResponse {
            enqueue(Data("not-json".utf8))
            return
        }
        enqueue(response(id: requestID, result: .object([
            "userAgent": .string("test"),
            "platformFamily": .string("unix"),
            "platformOs": .string("macos"),
        ])))
        if mode == .serverRequests {
            enqueue(jsonValue: .object([
                "id": .string("approval-1"),
                "method": .string("item/commandExecution/requestApproval"),
                "params": .object([:]),
            ]))
            enqueue(jsonValue: .object([
                "id": .string("unknown-1"),
                "method": .string("client/unknown"),
                "params": .object([:]),
            ]))
        }
    }

    private func enqueueModelListResponse(requestID: Int) {
        modelListCount += 1
        if mode == .blockFirstModelList, modelListCount == 1 { return }
        let inputModalities: JSONValue = mode == .textOnlyGenerationCompletes
            ? .array([.string("text")])
            : .array([.string("text"), .string("image")])
        enqueue(response(id: requestID, result: .object([
            "data": .array([
                .object([
                    "id": .string("default"),
                    "model": .string("default-model"),
                    "displayName": .string("Default"),
                    "description": .string("Default model"),
                    "hidden": .bool(false),
                    "isDefault": .bool(true),
                    "supportedReasoningEfforts": .array([
                        .object([
                            "reasoningEffort": .string("low"),
                            "description": .string("Fast responses"),
                        ]),
                        .object([
                            "reasoningEffort": .string("medium"),
                            "description": .string("Balances speed and reasoning"),
                        ]),
                        .object([
                            "reasoningEffort": .string("high"),
                            "description": .string("Deeper reasoning"),
                        ]),
                    ]),
                    "defaultReasoningEffort": .string("medium"),
                    "inputModalities": inputModalities,
                ]),
            ]),
            "nextCursor": .null,
        ])))
    }

    private func enqueueTurnStartResponse(requestID: Int) {
        enqueue(response(id: requestID, result: .object([
            "turn": .object([
                "id": .string("turn-1"),
                "status": .string("inProgress"),
            ]),
        ])))
        if mode == .generationFailsUnauthorized || mode == .generationFailsMessageOnlyUnauthorized {
            var error: [String: JSONValue] = ["message": .string("unauthorized while generating")]
            if mode == .generationFailsUnauthorized {
                error["codexErrorInfo"] = .string("unauthorized")
            }
            enqueue(jsonValue: .object([
                "method": .string("turn/completed"),
                "params": .object([
                    "threadId": .string("thread-1"),
                    "turn": .object([
                        "id": .string("turn-1"),
                        "status": .string("failed"),
                        "error": .object(error),
                    ]),
                ]),
            ]))
            return
        }
        guard mode == .generationCompletes || mode == .textOnlyGenerationCompletes else { return }
        enqueue(jsonValue: .object([
            "method": .string("item/completed"),
            "params": .object([
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "item": .object([
                    "id": .string("item-1"),
                    "type": .string("agentMessage"),
                    "text": .string(#"{"status":"ok"}"#),
                ]),
            ]),
        ]))
        enqueue(jsonValue: .object([
            "method": .string("turn/completed"),
            "params": .object([
                "threadId": .string("thread-1"),
                "turn": .object([
                    "id": .string("turn-1"),
                    "status": .string("completed"),
                    "items": .array([]),
                ]),
            ]),
        ]))
    }

    private func enqueueTestResponse(to requestID: Int, method: String) {
        switch method {
        case "test/blocked":
            return
        case "test/auth":
            enqueue(jsonValue: .object([
                "id": .number(Double(requestID)),
                "error": .object([
                    "code": .number(401),
                    "message": .string("authentication failed"),
                ]),
            ]))
        case "test/first" where mode == .outOfOrder:
            heldRequestID = requestID
        case "test/second" where mode == .outOfOrder:
            enqueue(response(id: requestID, result: .string("second")))
            enqueue(jsonValue: .object([
                "method": .string("server/notice"),
                "params": .object([:]),
            ]))
            if let heldRequestID {
                enqueue(response(id: heldRequestID, result: .string("first")))
                self.heldRequestID = nil
            }
        case _ where mode == .blockRequests:
            return
        default:
            enqueue(response(id: requestID, result: .object([:])))
        }
    }

    func receiveLine() async -> Data? {
        if !responses.isEmpty {
            return responses.removeFirst()
        }
        guard !isClosed else { return nil }
        return await withCheckedContinuation { continuation in
            receiveContinuation = continuation
        }
    }

    func close() async {
        guard !isClosed else { return }
        didStartClosing = true
        let closeWaiters = methodWaiters.removeValue(forKey: "transport/close") ?? []
        closeWaiters.forEach { $0.resume() }
        if mode == .blockClose {
            await withCheckedContinuation { continuation in
                closeContinuation = continuation
            }
        }
        isClosed = true
        receiveContinuation?.resume(returning: nil)
        receiveContinuation = nil
        for waiters in methodWaiters.values {
            waiters.forEach { $0.resume() }
        }
        methodWaiters.removeAll()
    }

    func messages() -> [JSONValue] {
        sentMessages
    }

    func waitUntilSent(_ method: String, count: Int = 1) async {
        if sentMessages.count(where: { $0.objectValue?["method"]?.stringValue == method }) >= count { return }
        await withCheckedContinuation { continuation in
            methodWaiters[method, default: []].append(continuation)
        }
    }

    func waitUntilResponded(to id: String) async {
        let key = "response:\(id)"
        if sentMessages.contains(where: { responseKey($0.objectValue?["id"]) == key }) { return }
        await withCheckedContinuation { continuation in
            methodWaiters[key, default: []].append(continuation)
        }
    }

    func waitUntilCloseStarted() async {
        if didStartClosing { return }
        await withCheckedContinuation { continuation in
            methodWaiters["transport/close", default: []].append(continuation)
        }
    }

    func finishClosing() {
        closeContinuation?.resume()
        closeContinuation = nil
    }

    func endOutput() {
        receiveContinuation?.resume(returning: nil)
        receiveContinuation = nil
    }

    func sendFromServer(_ message: JSONValue) {
        enqueue(jsonValue: message)
    }

    private func response(id: Int, result: JSONValue) -> Data {
        (try? JSONEncoder().encode(JSONValue.object([
            "id": .number(Double(id)),
            "result": result,
        ]))) ?? Data()
    }

    private func enqueue(jsonValue: JSONValue) {
        enqueue((try? JSONEncoder().encode(jsonValue)) ?? Data())
    }

    private func enqueue(_ data: Data) {
        if let continuation = receiveContinuation {
            receiveContinuation = nil
            continuation.resume(returning: data)
        } else {
            responses.append(data)
        }
    }

    private func resumeMethodWaiters(_ method: String) {
        let waiters = methodWaiters.removeValue(forKey: method) ?? []
        waiters.forEach { $0.resume() }
    }

    private func responseKey(_ id: JSONValue?) -> String? {
        if let value = id?.stringValue {
            return "response:\(value)"
        }
        if let value = id?.intValue {
            return "response:\(value)"
        }
        return nil
    }
}
