import DahliaRuntimeSupport
import Foundation
@testable import Dahlia

/// A scripted `pi --mode rpc` process. `reply` returns the records Pi would write after each command.
actor TestPiTransport: CodexAppServerTransport {
    typealias Reply = @Sendable (_ command: [String: JSONValue]) -> [JSONValue]

    private let reply: Reply
    private var lines: [Data] = []
    private var receiver: CheckedContinuation<Data?, Never>?
    typealias Match = @Sendable ([String: JSONValue]) -> Bool
    private var commandWaiters: [(Match, CheckedContinuation<[String: JSONValue], Never>)] = []
    private(set) var commands: [[String: JSONValue]] = []
    private(set) var isClosed = false

    init(reply: @escaping Reply = TestPiTransport.acknowledge) {
        self.reply = reply
    }

    func sendLine(_ data: Data) async throws {
        guard !isClosed else { throw CodexAppServerError.processExited(nil) }
        guard let command = try JSONDecoder().decode(JSONValue.self, from: data).objectValue else {
            throw CodexAppServerError.invalidProtocolResponse
        }
        commands.append(command)
        var waiting: [(Match, CheckedContinuation<[String: JSONValue], Never>)] = []
        for waiter in commandWaiters {
            if waiter.0(command) { waiter.1.resume(returning: command) } else { waiting.append(waiter) }
        }
        commandWaiters = waiting
        reply(command).forEach(emit)
    }

    func receiveLine() async -> Data? {
        if !lines.isEmpty { return lines.removeFirst() }
        if isClosed { return nil }
        return await withCheckedContinuation { receiver = $0 }
    }

    func close() async {
        isClosed = true
        receiver?.resume(returning: nil)
        receiver = nil
        commandWaiters.forEach { $0.1.resume(returning: [:]) }
        commandWaiters.removeAll()
    }

    func emit(_ record: JSONValue) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        if let receiver {
            self.receiver = nil
            receiver.resume(returning: data)
        } else {
            lines.append(data)
        }
    }

    /// Returns the first command of `type`, waiting for it when it has not been sent yet.
    func command(_ type: String) async -> [String: JSONValue] {
        await command { $0["type"]?.stringValue == type }
    }

    /// Returns the first matching command, waiting for it when it has not been sent yet. Returns `[:]` after close.
    func command(where match: @escaping Match) async -> [String: JSONValue] {
        if let command = commands.first(where: match) { return command }
        guard !isClosed else { return [:] }
        return await withCheckedContinuation { commandWaiters.append((match, $0)) }
    }

    static func acknowledge(_ command: [String: JSONValue]) -> [JSONValue] {
        guard let id = command["id"] else { return [] }
        return [response(id: id)]
    }

    static func response(id: JSONValue, data: JSONValue = .object([:])) -> JSONValue {
        .object(["type": .string("response"), "id": id, "success": .bool(true), "data": data])
    }

    static func assistantEnd(_ text: String, stopReason: String = "stop", errorMessage: String? = nil) -> JSONValue {
        var message: [String: JSONValue] = [
            "role": .string("assistant"),
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            "stopReason": .string(stopReason),
        ]
        if let errorMessage { message["errorMessage"] = .string(errorMessage) }
        return .object(["type": .string("message_end"), "message": .object(message)])
    }

    static func settled(aborted: Bool = false) -> JSONValue {
        .object(["type": .string("agent_settled"), "aborted": .bool(aborted)])
    }

    static func notify(_ message: String) -> JSONValue {
        .object([
            "type": .string("extension_ui_request"),
            "id": .string(UUID().uuidString),
            "method": .string("notify"),
            "message": .string(message),
        ])
    }

    static func bridgeRequest(id: String, method: String, payload: JSONValue) -> JSONValue {
        let text = String(decoding: (try? JSONEncoder().encode(payload)) ?? Data(), as: UTF8.self)
        return .object([
            "type": .string("extension_ui_request"),
            "id": .string(id),
            "method": .string("input"),
            "title": .string("dahlia:\(method)"),
            "placeholder": .string(text),
        ])
    }

    static func model(provider: String, id: String, input: [String] = ["text", "image"], thinkingLevelMap: JSONValue? = nil) -> JSONValue {
        var model: [String: JSONValue] = [
            "id": .string(id),
            "name": .string(id.uppercased()),
            "provider": .string(provider),
            "reasoning": .bool(true),
            "input": .array(input.map(JSONValue.string)),
        ]
        if let thinkingLevelMap { model["thinkingLevelMap"] = thinkingLevelMap }
        return .object(model)
    }
}

/// Builds a `PiRuntimeService` whose processes are `TestPiTransport`s chosen by launch mode.
struct TestPiRuntime {
    let service: PiRuntimeService
    let launches: LaunchLog
    let rootURL: URL
    let contextStore: CodexRuntimeContextStore

    final class LaunchLog: @unchecked Sendable {
        // Guarded by `lock`; written by the service's launcher and read by tests after awaiting it.
        private let lock = NSLock()
        private var storage: [PiRuntimeService.LaunchOptions] = []

        var all: [PiRuntimeService.LaunchOptions] {
            lock.withLock { storage }
        }

        func append(_ options: PiRuntimeService.LaunchOptions) {
            lock.withLock { storage.append(options) }
        }
    }

    init(
        provider: CodexRuntimeProvider = .local,
        tokenResolver: @escaping PiRuntimeService.TokenResolver = { _ in "test-token" },
        modelChoices: @escaping @Sendable (CodexRuntimeProvider) -> [String: Bool] = { _ in [:] },
        gatewayWorkspaces: @escaping @Sendable (CodexRuntimeProvider) -> [AgentMCPProvider] = { _ in [] },
        transport: @escaping @Sendable (PiRuntimeService.LaunchOptions) -> TestPiTransport
    ) {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "dahlia-pi-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        let contextStore = CodexRuntimeContextStore()
        contextStore.apply(provider)
        let launches = LaunchLog()
        self.rootURL = rootURL
        self.launches = launches
        self.contextStore = contextStore
        service = PiRuntimeService(
            agentLocator: PiAgentDirectoryLocator(applicationSupportURL: rootURL),
            contextStore: contextStore,
            configurationReadiness: { true },
            launcher: { options, _, _ in
                launches.append(options)
                return transport(options)
            },
            tokenResolver: tokenResolver,
            modelChoices: modelChoices,
            gatewayWorkspaces: gatewayWorkspaces
        )
    }

    static func modelsReply(_ models: [JSONValue]) -> TestPiTransport.Reply {
        { command in
            guard let id = command["id"] else { return [] }
            if command["type"]?.stringValue == "get_available_models" {
                return [TestPiTransport.response(id: id, data: .object(["models": .array(models)]))]
            }
            return [TestPiTransport.response(id: id)]
        }
    }
}

final class TestPiTransportLog: @unchecked Sendable {
    // Guarded by `lock`; appended by the launcher and read by tests after the awaited operation.
    private let lock = NSLock()
    private var storage: [TestPiTransport] = []
    private var waiters: [(Int, CheckedContinuation<TestPiTransport, Never>)] = []

    var all: [TestPiTransport] {
        lock.withLock { storage }
    }

    func append(_ transport: TestPiTransport) {
        let ready = lock.withLock {
            storage.append(transport)
            let ready = waiters.filter { $0.0 < storage.count }
            waiters.removeAll { $0.0 < storage.count }
            return ready.map { ($0.1, storage[$0.0]) }
        }
        ready.forEach { $0.0.resume(returning: $0.1) }
    }

    func allClosed() async -> Bool {
        for transport in all where await !transport.isClosed {
            return false
        }
        return true
    }

    /// Waits until the launcher has created the transport at `index`.
    func transport(at index: Int) async -> TestPiTransport {
        await withCheckedContinuation { continuation in
            let existing: TestPiTransport? = lock.withLock {
                if index < storage.count { return storage[index] }
                waiters.append((index, continuation))
                return nil
            }
            if let existing { continuation.resume(returning: existing) }
        }
    }
}

extension TestPiRuntime {
    /// Lists `models` and answers every structured generation with `reply`.
    static func generating(
        provider: CodexRuntimeProvider = .local,
        models: [JSONValue],
        reply: String,
        log: TestPiTransportLog = TestPiTransportLog()
    ) -> TestPiRuntime {
        TestPiRuntime(provider: provider) { options in
            let transport = if options.mode == .control {
                TestPiTransport(reply: modelsReply(models))
            } else {
                TestPiTransport { command in
                    guard let id = command["id"] else { return [] }
                    guard command["type"]?.stringValue == "prompt" else { return [TestPiTransport.response(id: id)] }
                    return [TestPiTransport.response(id: id), TestPiTransport.assistantEnd(reply), TestPiTransport.settled()]
                }
            }
            log.append(transport)
            return transport
        }
    }

    func argument(after flag: String, mode: PiRuntimeService.LaunchOptions.Mode = .summary) -> String? {
        guard let arguments = launches.all.last(where: { $0.mode == mode })?.arguments,
              let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}
