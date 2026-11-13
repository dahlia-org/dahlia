import DahliaRuntimeSupport
import Foundation

/// One `pi --mode rpc` child process. Responses match their command by ID, session events go to
/// `events`, and Dahlia's extension asks the app for tokens and approvals through `bridge`.
actor PiRPCConnection {
    /// Answers `ctx.ui.input("dahlia:<method>", <JSON>)` from Dahlia's Pi extension.
    typealias Bridge = @Sendable (_ method: String, _ payload: JSONValue) async throws -> JSONValue

    nonisolated let events: AsyncThrowingStream<JSONValue, any Error>
    private let eventContinuation: AsyncThrowingStream<JSONValue, any Error>.Continuation
    private let transport: any CodexAppServerTransport
    private let bridge: Bridge
    private var pending: [String: AsyncThrowingStream<JSONValue, any Error>.Continuation] = [:]
    private var nextID = 1
    private var failure: (any Error)?
    private var bridgeError: (any Error)?
    private var readerTask: Task<Void, Never>?
    /// Answers in progress, cancelled when the process goes away so a token login or approval does not outlive it.
    private var bridgeTasks: [String: Task<Void, Never>] = [:]

    init(transport: any CodexAppServerTransport, bridge: @escaping Bridge) {
        self.transport = transport
        self.bridge = bridge
        (events, eventContinuation) = AsyncThrowingStream.makeStream()
    }

    func start() {
        guard readerTask == nil else { return }
        readerTask = Task { await self.readLoop() }
    }

    /// Sends one command and returns its `data`. A failed command throws its error message.
    func request(_ type: String, _ fields: [String: JSONValue] = [:], timeout: Duration? = nil) async throws -> JSONValue {
        if let failure { throw failure }
        let id = "dahlia-\(nextID)"
        nextID += 1
        var command = fields
        command["type"] = .string(type)
        command["id"] = .string(id)
        let (response, continuation) = AsyncThrowingStream<JSONValue, any Error>.makeStream()
        pending[id] = continuation
        defer { pending.removeValue(forKey: id) }
        try await write(.object(command))
        return try await Self.withTimeout(timeout) {
            for try await data in response {
                return data
            }
            throw CancellationError()
        }
    }

    func finishHandledPrompt(turnID: String) {
        // The marker follows all notifications read before the prompt acknowledgement.
        eventContinuation.yield(.object(["type": .string("dahlia_prompt_handled"), "turnID": .string(turnID)]))
    }

    /// False once the process has exited or been closed.
    var isOpen: Bool {
        failure == nil
    }

    /// The last error Dahlia could not answer the extension with, such as an expired sign-in. Reading clears it.
    func takeBridgeError() -> (any Error)? {
        defer { bridgeError = nil }
        return bridgeError
    }

    func close() async {
        fail(CancellationError())
        await transport.close()
        readerTask?.cancel()
    }

    private func write(_ record: JSONValue) async throws {
        try await transport.sendLine(JSONEncoder().encode(record))
    }

    private func readLoop() async {
        do {
            while let line = try await transport.receiveLine() {
                guard let object = try JSONDecoder().decode(JSONValue.self, from: line).objectValue else {
                    throw PiRuntimeError.invalidProtocolResponse
                }
                handle(object)
            }
            fail(PiRuntimeError.processExited(nil))
        } catch {
            fail(error)
        }
    }

    private func handle(_ record: [String: JSONValue]) {
        switch record["type"]?.stringValue {
        case "response":
            guard let id = record["id"]?.stringValue, let continuation = pending[id] else { return }
            if record["success"]?.boolValue == true {
                continuation.yield(record["data"] ?? .null)
            } else {
                continuation.finish(throwing: PiRuntimeError.rpcError(
                    code: nil,
                    message: record["error"]?.stringValue ?? ""
                ))
            }
        case "extension_ui_request":
            handleUIRequest(record)
        default:
            eventContinuation.yield(.object(record))
        }
    }

    private func handleUIRequest(_ record: [String: JSONValue]) {
        guard let id = record["id"]?.stringValue else { return }
        switch record["method"]?.stringValue {
        case "notify":
            eventContinuation.yield(.object(record))
        case "input":
            guard let title = record["title"]?.stringValue, title.hasPrefix("dahlia:") else {
                return respond(id: id, value: nil)
            }
            let method = String(title.dropFirst("dahlia:".count))
            let payload = record["placeholder"]?.stringValue
                .flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) } ?? .null
            let bridge = bridge
            bridgeTasks[id] = Task {
                defer { self.bridgeTasks[id] = nil }
                do {
                    try await self.respond(id: id, value: bridge(method, payload))
                } catch {
                    self.bridgeError = error
                    self.respond(id: id, value: nil)
                }
            }
        case "select", "confirm", "editor":
            respond(id: id, value: nil)
        default:
            return
        }
    }

    private func respond(id: String, value: JSONValue?) {
        var response: [String: JSONValue] = ["type": .string("extension_ui_response"), "id": .string(id)]
        if let value, let text = try? String(decoding: JSONEncoder().encode(value), as: UTF8.self) {
            response["value"] = .string(text)
        } else {
            response["cancelled"] = .bool(true)
        }
        Task { try? await self.write(.object(response)) }
    }

    private func fail(_ error: any Error) {
        guard failure == nil else { return }
        failure = error
        for continuation in pending.values {
            continuation.finish(throwing: error)
        }
        pending.removeAll()
        bridgeTasks.values.forEach { $0.cancel() }
        bridgeTasks.removeAll()
        eventContinuation.finish(throwing: error)
    }

    static func withTimeout<T: Sendable>(
        _ timeout: Duration?,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard let timeout else { return try await operation() }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw PiRuntimeError.requestTimedOut("Pi")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}
