// JSON-RPC lifecycle and protocol handlers remain colocated behind one actor boundary.
// swiftlint:disable file_length

import Foundation
import OSLog

actor CodexAppServerService {
    typealias TransportFactory = @Sendable () throws -> any CodexAppServerTransport
    typealias ConfigurationReadiness = @Sendable () async -> Bool

    struct AccountStatus: Equatable {
        let isAuthenticated: Bool
        let requiresOpenAIAuth: Bool
        let label: String?

        var canUseCodex: Bool {
            isAuthenticated || !requiresOpenAIAuth
        }
    }

    struct LoginSession: Equatable {
        let id: String
        let authorizationURL: URL
    }

    static let shared = CodexAppServerService()

    private struct PendingRequest {
        let method: String
        let continuation: CheckedContinuation<JSONValue, any Error>
    }

    private struct TurnKey: Hashable {
        let threadID: String
        let turnID: String
    }

    private struct TurnWaiter {
        var finalMessage: String?
        let continuation: CheckedContinuation<String, any Error>
        let timeoutTask: Task<Void, Never>
    }

    private struct GenerationContext {
        var threadID: String?
        var key: TurnKey?
        var temporaryDirectory: URL?
        var didSendInterrupt = false
    }

    private enum LoginOutcome {
        case succeeded
        case failed(String?)
    }

    private let transportFactory: TransportFactory
    private let configurationReadiness: ConfigurationReadiness
    private let clock: any CodexAppServerClock
    private let transportTimeout: Duration
    private let summaryTimeout: Duration
    private let logger = Logger(subsystem: "com.dahlia", category: "CodexAppServer")
    private var transport: (any CodexAppServerTransport)?
    private var readerTask: Task<Void, Never>?
    private var connectionGeneration = 0
    private var nextRequestID = 1
    private var pendingRequests: [Int: PendingRequest] = [:]
    private var turnWaiters: [TurnKey: TurnWaiter] = [:]
    private var turnSubscribers: [TurnKey: [UUID: AsyncThrowingStream<JSONValue, any Error>.Continuation]] = [:]
    private var bufferedTurnMessages: [TurnKey: [JSONValue]] = [:]
    private var startupWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var generations: [UUID: GenerationContext] = [:]
    private var generationDrainWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var cachedModels: [CodexModel]?
    private var cachedAccountStatus: AccountStatus?
    private var cachedConfigReadResult: JSONValue?
    private var loginWaiters: [String: CheckedContinuation<Void, any Error>] = [:]
    private var bufferedLoginOutcomes: [String: LoginOutcome] = [:]
    private var bufferedLoginOutcomeOrder: [String] = []
    private var ignoredLoginIDs: Set<String> = []
    private var isStarting = false
    private var isStoppingConnection = false
    private var connectionStopWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var isInitialized = false
    private var isShuttingDown = false
    #if DEBUG
        private var activeTurnTestWaiters: [CheckedContinuation<Void, Never>] = []
        private var generationDrainTestWaiters: [CheckedContinuation<Void, Never>] = []
    #endif

    init(
        launcher: any CodexAppServerLaunching = BundledCodexAppServerLauncher(),
        clock: any CodexAppServerClock = ContinuousCodexAppServerClock(),
        transportTimeout: Duration = .seconds(15),
        summaryTimeout: Duration = .seconds(270),
        configurationReadiness: @escaping ConfigurationReadiness = {
            await MainActor.run { AppSettings.shared.isCodexAccountConfigurationCurrent }
        }
    ) {
        transportFactory = { try launcher.launch() }
        self.configurationReadiness = configurationReadiness
        self.clock = clock
        self.transportTimeout = transportTimeout
        self.summaryTimeout = summaryTimeout
    }

    init(
        transportFactory: @escaping TransportFactory,
        clock: any CodexAppServerClock = ContinuousCodexAppServerClock(),
        transportTimeout: Duration = .seconds(15),
        summaryTimeout: Duration = .seconds(270),
        configurationReadiness: @escaping ConfigurationReadiness = { true }
    ) {
        self.transportFactory = transportFactory
        self.configurationReadiness = configurationReadiness
        self.clock = clock
        self.transportTimeout = transportTimeout
        self.summaryTimeout = summaryTimeout
    }

    func start() async throws {
        if isInitialized { return }
        if isStoppingConnection {
            await waitForConnectionStop()
            try Task.checkCancellation()
            return try await start()
        }
        guard !isShuttingDown else { throw CancellationError() }
        if isStarting {
            return try await waitForStartup()
        }

        isStarting = true
        do {
            try await bootstrap()
            isStarting = false
            isInitialized = true
            resumeStartupWaiters()
        } catch {
            isStarting = false
            await stopConnection(error: error)
            resumeStartupWaiters(throwing: error)
            throw error
        }
    }

    func shutdown() async {
        isShuttingDown = true
        cachedModels = nil
        cachedAccountStatus = nil
        await stopConnection(error: CancellationError())
        resumeStartupWaiters(throwing: CancellationError())
        resumeGenerationDrainWaiters(throwing: CancellationError())
        isStarting = false
    }

    func reloadConfiguration() async throws {
        guard !isShuttingDown else { throw CancellationError() }
        try await waitForGenerationsToFinish()
        await stopConnection(error: CancellationError())
        try Task.checkCancellation()
        try await start()
    }

    func request(
        method: String,
        params: JSONValue = .object([:]),
        timeout: Duration? = nil
    ) async throws -> JSONValue {
        try await start()
        return try await requestOnCurrentConnection(
            method: method,
            params: params,
            timeout: timeout ?? transportTimeout
        )
    }

    func models(
        forceRefresh: Bool = false,
        bypassConfigurationCheck: Bool = false
    ) async throws -> [CodexModel] {
        if !bypassConfigurationCheck {
            try await requireCurrentConfiguration()
        }
        let account = try await accountStatus(forceRefresh: false)
        guard account.canUseCodex else { throw CodexAppServerError.notLoggedIn }
        if !forceRefresh, let cachedModels { return cachedModels }
        var models: [CodexModel] = []
        var cursor: String?

        repeat {
            var params: [String: JSONValue] = ["includeHidden": .bool(false)]
            if let cursor {
                params["cursor"] = .string(cursor)
            }
            let result = try await request(method: "model/list", params: .object(params))
            let response: ModelListResponse = try decode(result)
            models.append(contentsOf: response.data.filter { !$0.hidden })
            cursor = response.nextCursor
        } while cursor != nil

        cachedModels = models
        return models
    }

    func accountStatus(forceRefresh: Bool = true) async throws -> AccountStatus {
        try await start()
        if !forceRefresh, let cachedAccountStatus {
            return cachedAccountStatus
        }
        let result = try await request(
            method: "account/read",
            params: .object(["refreshToken": .bool(false)])
        )
        let status = try Self.parseAccountStatus(result)
        cachedAccountStatus = status
        return status
    }

    func startChatGPTLogin() async throws -> LoginSession {
        let result = try await request(
            method: "account/login/start",
            params: .object([
                "appBrand": .string("codex"),
                "type": .string("chatgpt"),
                "useHostedLoginSuccessPage": .bool(true),
            ])
        )
        guard let object = result.objectValue,
              object["type"]?.stringValue == "chatgpt",
              let loginID = object["loginId"]?.stringValue?.nilIfBlank,
              let urlString = object["authUrl"]?.stringValue,
              let authorizationURL = URL(string: urlString),
              authorizationURL.scheme?.lowercased() == "https",
              authorizationURL.host != nil
        else {
            throw CodexAppServerError.invalidProtocolResponse
        }

        ignoredLoginIDs.remove(loginID)
        return LoginSession(id: loginID, authorizationURL: authorizationURL)
    }

    func waitForLoginCompletion(loginID: String) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if let outcome = bufferedLoginOutcomes.removeValue(forKey: loginID) {
                    bufferedLoginOutcomeOrder.removeAll { $0 == loginID }
                    Self.resume(continuation, with: outcome)
                } else if loginWaiters[loginID] != nil {
                    continuation.resume(throwing: CodexAppServerError.invalidProtocolResponse)
                } else {
                    loginWaiters[loginID] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelLoginAfterWaiterCancellation(loginID) }
        }
    }

    func cancelLogin(loginID: String) async throws {
        ignoredLoginIDs.insert(loginID)
        cancelLoginWaiter(loginID)
        _ = try await request(
            method: "account/login/cancel",
            params: .object(["loginId": .string(loginID)])
        )
    }

    func logout() async throws {
        _ = try await request(method: "account/logout", params: .null)
        cachedModels = nil
        cachedAccountStatus = AccountStatus(
            isAuthenticated: false,
            requiresOpenAIAuth: true,
            label: nil
        )
    }

    private nonisolated static func parseAccountStatus(_ result: JSONValue) throws -> AccountStatus {
        guard let object = result.objectValue,
              let requiresOpenAIAuth = object["requiresOpenaiAuth"]?.boolValue
        else {
            throw CodexAppServerError.invalidProtocolResponse
        }
        guard let accountValue = object["account"], accountValue != .null else {
            return AccountStatus(
                isAuthenticated: false,
                requiresOpenAIAuth: requiresOpenAIAuth,
                label: nil
            )
        }
        guard let account = accountValue.objectValue else {
            throw CodexAppServerError.invalidProtocolResponse
        }
        let label = account["email"]?.stringValue
            ?? account["planType"]?.stringValue
            ?? account["type"]?.stringValue
        return AccountStatus(
            isAuthenticated: true,
            requiresOpenAIAuth: requiresOpenAIAuth,
            label: label
        )
    }

    func notifications(threadID: String, turnID: String) -> AsyncThrowingStream<JSONValue, any Error> {
        let key = TurnKey(threadID: threadID, turnID: turnID)
        let subscriberID = UUID()
        return AsyncThrowingStream { continuation in
            turnSubscribers[key, default: [:]][subscriberID] = continuation
            let bufferedMessages = bufferedTurnMessages.removeValue(forKey: key) ?? []
            bufferedMessages.forEach { continuation.yield($0) }
            if bufferedMessages.contains(where: Self.isTurnCompletionMessage) {
                turnSubscribers[key]?.removeValue(forKey: subscriberID)
                if turnSubscribers[key]?.isEmpty == true {
                    turnSubscribers.removeValue(forKey: key)
                }
                continuation.finish()
            }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeTurnSubscriber(subscriberID, for: key) }
            }
        }
    }

    // swiftformat:disable:next modifierOrder
    nonisolated private static func isTurnCompletionMessage(_ message: JSONValue) -> Bool {
        message.objectValue?["method"]?.stringValue == "turn/completed"
    }

    func chatThreadConfiguration(reasoningEffort: String, vaultID: UUID, helperURL: URL) async throws -> JSONValue {
        try await requireCurrentConfiguration()
        let configuration = try await configReadResult()
        return try Self.chatThreadConfig(
            from: configuration,
            reasoningEffort: reasoningEffort,
            helperURL: helperURL,
            vaultID: vaultID
        )
    }

    func generate(
        _ request: CodexAppServerRequest,
        bypassConfigurationCheck: Bool = false
    ) async throws -> String {
        if !bypassConfigurationCheck {
            try await requireCurrentConfiguration()
        }
        let generationID = UUID()
        generations[generationID] = GenerationContext()

        do {
            let result = try await performGeneration(request, generationID: generationID)
            await finishGeneration(generationID)
            return result
        } catch {
            let shouldInterrupt = error is CancellationError || Self.isSummaryTimeout(error)
            let cleanup = Task {
                await finishGeneration(
                    generationID,
                    interrupt: shouldInterrupt
                )
            }
            await cleanup.value
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    nonisolated static func summaryThreadConfig(
        from configReadResult: JSONValue,
        reasoningEffort: String = CodexReasoningEffortOption.defaultValue,
        dahliaMCP: CodexAppServerDahliaMCPConfiguration? = nil
    ) throws -> JSONValue {
        guard case var .object(config) = try restrictedThreadConfig(
            from: configReadResult,
            reasoningEffort: reasoningEffort
        ) else {
            throw CodexAppServerError.invalidProtocolResponse
        }
        if let dahliaMCP {
            guard !dahliaMCP.allowedMeetingIDs.isEmpty else {
                throw CodexAppServerError.invalidProtocolResponse
            }
            var servers = config["mcp_servers"]?.objectValue ?? [:]
            servers["dahlia"] = dahliaMCPServer(
                executableURL: dahliaMCP.executableURL,
                vaultID: dahliaMCP.vaultID,
                allowedMeetingIDs: dahliaMCP.allowedMeetingIDs
            )
            config["mcp_servers"] = .object(servers)
        }
        return .object(config)
    }

    nonisolated static func chatThreadConfig(
        from configReadResult: JSONValue,
        reasoningEffort: String = CodexReasoningEffortOption.defaultValue,
        helperURL: URL,
        vaultID: UUID
    ) throws -> JSONValue {
        guard case var .object(config) = try restrictedThreadConfig(
            from: configReadResult,
            reasoningEffort: reasoningEffort
        ) else {
            throw CodexAppServerError.invalidProtocolResponse
        }
        var servers = config["mcp_servers"]?.objectValue ?? [:]
        servers["dahlia"] = dahliaMCPServer(
            executableURL: helperURL,
            vaultID: vaultID,
            allowsWrites: true
        )
        config["mcp_servers"] = .object(servers)
        config["web_search"] = .string("live")
        return .object(config)
    }

    private nonisolated static func dahliaMCPServer(
        executableURL: URL,
        vaultID: UUID,
        allowedMeetingIDs: [UUID] = [],
        allowsWrites: Bool = false
    ) -> JSONValue {
        let meetingArguments = allowedMeetingIDs.flatMap { meetingID in
            [JSONValue.string("--meeting-id"), .string(meetingID.uuidString)]
        }
        let writeArguments: [JSONValue] = allowsWrites ? [.string("--write")] : []
        return .object([
            "args": .array([
                .string("--vault-id"),
                .string(vaultID.uuidString),
            ] + meetingArguments + writeArguments),
            "command": .string(executableURL.path),
            "enabled": .bool(true),
        ])
    }

    // swiftformat:disable:next modifierOrder
    nonisolated private static func restrictedThreadConfig(
        from configReadResult: JSONValue,
        reasoningEffort: String
    ) throws -> JSONValue {
        guard let config = configReadResult.objectValue?["config"]?.objectValue else {
            throw CodexAppServerError.invalidProtocolResponse
        }

        let mcpServers: [String: JSONValue]
        if let value = config["mcp_servers"], value != .null {
            guard let servers = value.objectValue else {
                throw CodexAppServerError.invalidProtocolResponse
            }
            mcpServers = servers
        } else {
            mcpServers = [:]
        }
        let disabledMCPServers = mcpServers.mapValues { _ in
            JSONValue.object(["enabled": .bool(false)])
        }

        return .object([
            "features.apps": .bool(false),
            "features.codex_hooks": .bool(false),
            "features.memory_tool": .bool(false),
            "features.plugins": .bool(false),
            "include_apps_instructions": .bool(false),
            "mcp_oauth_credentials_store": .string("file"),
            "mcp_servers": .object(disabledMCPServers),
            "memories.dedicated_tools": .bool(false),
            "memories.use_memories": .bool(false),
            "model_reasoning_effort": .string(reasoningEffort.nilIfBlank ?? CodexReasoningEffortOption.defaultValue),
            "orchestrator.mcp.enabled": .bool(false),
            "skills.include_instructions": .bool(false),
        ])
    }
}

private extension CodexAppServerService {
    private func bootstrap() async throws {
        let newTransport: any CodexAppServerTransport
        do {
            newTransport = try transportFactory()
        } catch let error as CodexAppServerError {
            throw error
        } catch {
            throw CodexAppServerError.launchFailed(error.localizedDescription)
        }

        connectionGeneration += 1
        let generation = connectionGeneration
        transport = newTransport
        readerTask = Task { [weak self] in
            await self?.readLoop(transport: newTransport, generation: generation)
        }

        _ = try await requestOnCurrentConnection(
            method: "initialize",
            params: .object([
                "clientInfo": .object([
                    "name": .string("dahlia"),
                    "title": .string("Dahlia"),
                    "version": .string(
                        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
                    ),
                ]),
            ]),
            timeout: transportTimeout
        )
        try await sendMessage(.object([
            "method": .string("initialized"),
            "params": .object([:]),
        ]))
        let accountResult = try await requestOnCurrentConnection(
            method: "account/read",
            params: .object(["refreshToken": .bool(false)]),
            timeout: transportTimeout
        )
        cachedAccountStatus = try Self.parseAccountStatus(accountResult)
    }

    private func performGeneration(
        _ request: CodexAppServerRequest,
        generationID: UUID
    ) async throws -> String {
        try await start()
        try Task.checkCancellation()

        let account = try await accountStatus(forceRefresh: false)
        guard account.canUseCodex else { throw CodexAppServerError.notLoggedIn }
        let availableModels = try await models()
        let selectedModel = request.model
            .flatMap { requestedModel in availableModels.first { $0.model == requestedModel } }
            ?? availableModels.first(where: \CodexModel.isDefault)
        let shouldOmitImages = request.inputs.contains(where: \CodexAppServerInput.isImage)
            && selectedModel?.supportsImages == false
        let generationInputs: [CodexAppServerInput]
        if shouldOmitImages {
            let imageCount = request.inputs.count(where: \CodexAppServerInput.isImage)
            logger.notice("Omitting \(imageCount, privacy: .public) screenshot image(s) for a text-only Codex model")
            generationInputs = request.inputs.filter { !$0.isImageRelated }
        } else {
            generationInputs = request.inputs
        }
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: "dahlia-codex-\(generationID.uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        generations[generationID]?.temporaryDirectory = temporaryDirectory

        let configResult = try await configReadResult()
        var threadParams: [String: JSONValue] = try [
            "approvalPolicy": .string("never"),
            "config": Self.summaryThreadConfig(
                from: configResult,
                reasoningEffort: request.reasoningEffort,
                dahliaMCP: request.dahliaMCP
            ),
            "cwd": .string(temporaryDirectory.path),
            "developerInstructions": .string(request.developerInstructions + Self.summaryToolInstruction(
                allowsDahliaMCP: request.dahliaMCP != nil
            )),
            "ephemeral": .bool(true),
            "sandbox": .string("read-only"),
        ]
        if let selectedModel {
            threadParams["model"] = .string(selectedModel.model)
        }
        let threadResult = try await self.request(method: "thread/start", params: .object(threadParams))
        guard let threadID = threadResult.objectValue?["thread"]?.objectValue?["id"]?.stringValue else {
            throw CodexAppServerError.invalidProtocolResponse
        }
        generations[generationID]?.threadID = threadID

        let inputs = generationInputs.map { input in
            switch input {
            case let .text(text), let .imageMetadata(text):
                JSONValue.object(["type": .string("text"), "text": .string(text)])
            case let .imageDataURI(uri):
                JSONValue.object(["type": .string("image"), "url": .string(uri)])
            }
        }
        let outputSchema = try JSONDecoder().decode(JSONValue.self, from: request.outputSchema)
        let turnResult = try await self.request(
            method: "turn/start",
            params: .object([
                "input": .array(inputs),
                "outputSchema": outputSchema,
                "threadId": .string(threadID),
            ])
        )
        guard let turnID = turnResult.objectValue?["turn"]?.objectValue?["id"]?.stringValue else {
            throw CodexAppServerError.invalidProtocolResponse
        }

        let key = TurnKey(threadID: threadID, turnID: turnID)
        generations[generationID]?.key = key
        #if DEBUG
            let testWaiters = activeTurnTestWaiters
            activeTurnTestWaiters.removeAll()
            testWaiters.forEach { $0.resume() }
        #endif
        return try await waitForTurn(key, timeout: summaryTimeout)
    }

    private nonisolated static func summaryToolInstruction(allowsDahliaMCP: Bool) -> String {
        if allowsDahliaMCP {
            return "\nYou may call only the Dahlia get_meeting tool. Do not call any other tool. Return only the requested JSON."
        }
        return "\nDo not call tools. Return only the requested JSON."
    }

    private func finishGeneration(_ generationID: UUID, interrupt: Bool = false) async {
        if interrupt {
            await interruptGeneration(generationID)
        }
        guard let context = generations.removeValue(forKey: generationID) else { return }
        if let key = context.key {
            cancelTurnWaiter(key)
            bufferedTurnMessages.removeValue(forKey: key)
        }
        if !isShuttingDown,
           isInitialized,
           transport != nil,
           let threadID = context.threadID {
            _ = try? await requestOnCurrentConnection(
                method: "thread/unsubscribe",
                params: .object(["threadId": .string(threadID)]),
                timeout: transportTimeout
            )
        }
        if let temporaryDirectory = context.temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        resumeGenerationDrainWaitersIfIdle()
    }

    private func requestOnCurrentConnection(
        method: String,
        params: JSONValue,
        timeout: Duration
    ) async throws -> JSONValue {
        guard transport != nil else { throw CodexAppServerError.processExited(nil) }
        let requestID = nextRequestID
        nextRequestID += 1

        return try await withThrowingTaskGroup(of: JSONValue.self) { group in
            group.addTask {
                try await self.awaitResponse(requestID: requestID, method: method, params: params)
            }
            group.addTask {
                try await self.clock.sleep(for: timeout)
                throw CodexAppServerError.requestTimedOut(method)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }

    private func awaitResponse(
        requestID: Int,
        method: String,
        params: JSONValue
    ) async throws -> JSONValue {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pendingRequests[requestID] = PendingRequest(method: method, continuation: continuation)
                Task {
                    do {
                        try await self.sendMessage(.object([
                            "id": .number(Double(requestID)),
                            "method": .string(method),
                            "params": params,
                        ]))
                    } catch {
                        self.failRequest(requestID, error: error)
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(requestID) }
        }
    }

    private func sendMessage(_ message: JSONValue) async throws {
        guard let transport else { throw CodexAppServerError.processExited(nil) }
        try await transport.sendLine(JSONEncoder().encode(message))
    }

    private func readLoop(transport: any CodexAppServerTransport, generation: Int) async {
        do {
            while let line = try await transport.receiveLine() {
                try Task.checkCancellation()
                let message: JSONValue
                do {
                    message = try JSONDecoder().decode(JSONValue.self, from: line)
                } catch {
                    throw CodexAppServerError.invalidProtocolResponse
                }
                try await handle(message)
            }
            if !Task.isCancelled {
                await handleTransportFailure(CodexAppServerError.processExited(nil), generation: generation)
            }
        } catch is CancellationError {
            // Explicit shutdown or connection replacement.
        } catch {
            await handleTransportFailure(error, generation: generation)
        }
    }

    private func handle(_ message: JSONValue) async throws {
        guard let object = message.objectValue else {
            throw CodexAppServerError.invalidProtocolResponse
        }

        if let requestID = object["id"],
           let method = object["method"]?.stringValue {
            try await handleServerRequest(id: requestID, method: method)
            return
        }

        if let requestID = object["id"]?.intValue {
            guard let pending = pendingRequests.removeValue(forKey: requestID) else { return }
            if let error = object["error"]?.objectValue {
                let message = error["message"]?.stringValue ?? L10n.codexUnknownError
                let code = error["code"]?.intValue
                if Self.isAuthenticationRPCError(
                    data: error["data"],
                    message: message,
                    method: pending.method
                ) {
                    pending.continuation.resume(throwing: CodexAppServerError.notLoggedIn)
                } else {
                    pending.continuation.resume(throwing: CodexAppServerError.rpcError(
                        code: code,
                        message: message
                    ))
                }
            } else if let result = object["result"] {
                pending.continuation.resume(returning: result)
            } else {
                pending.continuation.resume(throwing: CodexAppServerError.invalidProtocolResponse)
            }
            return
        }

        guard object["method"]?.stringValue != nil else {
            throw CodexAppServerError.invalidProtocolResponse
        }
        if try handleAccountNotification(object) {
            return
        }
        routeTurnMessage(message)
    }

    private func handleAccountNotification(_ object: [String: JSONValue]) throws -> Bool {
        guard let method = object["method"]?.stringValue else { return false }
        switch method {
        case "account/login/completed":
            guard let params = object["params"]?.objectValue,
                  let success = params["success"]?.boolValue
            else {
                throw CodexAppServerError.invalidProtocolResponse
            }
            cachedAccountStatus = nil
            cachedModels = nil
            guard let loginID = params["loginId"]?.stringValue else { return true }
            if ignoredLoginIDs.remove(loginID) != nil {
                bufferedLoginOutcomes.removeValue(forKey: loginID)
                bufferedLoginOutcomeOrder.removeAll { $0 == loginID }
                return true
            }
            let outcome: LoginOutcome = success
                ? .succeeded
                : .failed(params["error"]?.stringValue)
            if let waiter = loginWaiters.removeValue(forKey: loginID) {
                Self.resume(waiter, with: outcome)
            } else {
                bufferedLoginOutcomeOrder.removeAll { $0 == loginID }
                bufferedLoginOutcomeOrder.append(loginID)
                bufferedLoginOutcomes[loginID] = outcome
                while bufferedLoginOutcomeOrder.count > 10 {
                    let oldestID = bufferedLoginOutcomeOrder.removeFirst()
                    bufferedLoginOutcomes.removeValue(forKey: oldestID)
                }
            }
            return true
        case "account/updated":
            cachedAccountStatus = nil
            cachedModels = nil
            return true
        default:
            return false
        }
    }

    private func handleServerRequest(id: JSONValue, method: String) async throws {
        switch method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            try await sendMessage(.object([
                "id": id,
                "result": .object(["decision": .string("decline")]),
            ]))
        case "applyPatchApproval", "execCommandApproval":
            try await sendMessage(.object([
                "id": id,
                "result": .object(["decision": .string("denied")]),
            ]))
        case "item/permissions/requestApproval":
            try await sendServerRequestError(
                id: id,
                code: -32000,
                message: "Permission request denied"
            )
        default:
            try await sendServerRequestError(
                id: id,
                code: -32601,
                message: "Client method not supported"
            )
        }
    }

    private func sendServerRequestError(id: JSONValue, code: Int, message: String) async throws {
        try await sendMessage(.object([
            "id": id,
            "error": .object([
                "code": .number(Double(code)),
                "message": .string(message),
            ]),
        ]))
    }

    private func routeTurnMessage(_ message: JSONValue) {
        guard let object = message.objectValue,
              let method = object["method"]?.stringValue,
              let params = object["params"]?.objectValue,
              let threadID = params["threadId"]?.stringValue
        else { return }

        let turnID: String? = if method == "turn/completed" {
            params["turn"]?.objectValue?["id"]?.stringValue
        } else {
            params["turnId"]?.stringValue
        }
        guard let turnID else { return }
        let key = TurnKey(threadID: threadID, turnID: turnID)
        let hasSubscribers = turnSubscribers[key]?.isEmpty == false
        turnSubscribers[key]?.values.forEach { $0.yield(message) }
        if turnWaiters[key] != nil {
            processTurnMessage(message, for: key)
        } else if !hasSubscribers {
            bufferTurnMessage(message, for: key)
        }
        if method == "turn/completed" {
            finishTurnSubscribers(for: key)
        }
    }

    private func bufferTurnMessage(_ message: JSONValue, for key: TurnKey) {
        var messages = bufferedTurnMessages[key, default: []]
        if let object = message.objectValue,
           object["method"]?.stringValue == "item/agentMessage/delta",
           let params = object["params"]?.objectValue,
           let itemID = params["itemId"]?.stringValue,
           let delta = params["delta"]?.stringValue,
           let last = messages.indices.last,
           var lastObject = messages[last].objectValue,
           lastObject["method"]?.stringValue == "item/agentMessage/delta",
           var lastParams = lastObject["params"]?.objectValue,
           lastParams["itemId"]?.stringValue == itemID,
           let priorDelta = lastParams["delta"]?.stringValue {
            lastParams["delta"] = .string(priorDelta + delta)
            lastObject["params"] = .object(lastParams)
            messages[last] = .object(lastObject)
        } else {
            messages.append(message)
        }
        bufferedTurnMessages[key] = Array(messages.suffix(100))
    }

    private func waitForTurn(_ key: TurnKey, timeout: Duration) async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let timeoutTask = Task { [weak self] in
                    do {
                        try await self?.clock.sleep(for: timeout)
                        await self?.timeoutTurnWaiter(key)
                    } catch {
                        // Completion and cancellation both stop the timeout task.
                    }
                }
                turnWaiters[key] = TurnWaiter(
                    finalMessage: nil,
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
                let messages = bufferedTurnMessages.removeValue(forKey: key) ?? []
                for message in messages where turnWaiters[key] != nil {
                    processTurnMessage(message, for: key)
                }
            }
        } onCancel: {
            Task { await self.cancelTurnWaiter(key) }
        }
    }

    private func processTurnMessage(_ message: JSONValue, for key: TurnKey) {
        guard var waiter = turnWaiters[key],
              let object = message.objectValue,
              let method = object["method"]?.stringValue,
              let params = object["params"]?.objectValue
        else { return }

        if method == "item/completed",
           let item = params["item"]?.objectValue,
           item["type"]?.stringValue == "agentMessage",
           let text = item["text"]?.stringValue {
            waiter.finalMessage = text
            turnWaiters[key] = waiter
            return
        }

        guard method == "turn/completed",
              let turn = params["turn"]?.objectValue,
              let status = turn["status"]?.stringValue
        else { return }
        turnWaiters.removeValue(forKey: key)
        waiter.timeoutTask.cancel()
        switch status {
        case "completed":
            if let finalMessage = waiter.finalMessage?.nilIfBlank {
                waiter.continuation.resume(returning: finalMessage)
            } else {
                waiter.continuation.resume(throwing: CodexAppServerError.emptyResponse)
            }
        case "interrupted":
            waiter.continuation.resume(throwing: CodexAppServerError.turnInterrupted)
        case "failed":
            let turnError = turn["error"]?.objectValue
            let detail = turnError?["message"]?.stringValue
            if Self.isAuthenticationTurnError(turnError) {
                waiter.continuation.resume(throwing: CodexAppServerError.notLoggedIn)
            } else if Self.isExpectedProviderAuthenticationTurnError(turnError) {
                waiter.continuation.resume(throwing: CodexAppServerError.providerAuthenticationFailed(detail))
            } else {
                waiter.continuation.resume(throwing: CodexAppServerError.turnFailed(detail))
            }
        default:
            waiter.continuation.resume(throwing: CodexAppServerError.invalidProtocolResponse)
        }
    }

    private func handleTransportFailure(_ error: any Error, generation: Int) async {
        guard generation == connectionGeneration, !isShuttingDown else { return }
        await stopConnection(error: error)
    }

    private func stopConnection(error: any Error) async {
        if isStoppingConnection {
            await waitForConnectionStop()
            return
        }
        isStoppingConnection = true
        defer {
            isStoppingConnection = false
            resumeConnectionStopWaiters()
        }
        connectionGeneration += 1
        isInitialized = false
        cachedModels = nil
        cachedAccountStatus = nil
        cachedConfigReadResult = nil
        let currentTransport = transport
        transport = nil
        readerTask?.cancel()
        readerTask = nil

        let requests = pendingRequests.values
        pendingRequests.removeAll()
        for request in requests {
            request.continuation.resume(throwing: error)
        }
        let waiters = turnWaiters.values
        turnWaiters.removeAll()
        bufferedTurnMessages.removeAll()
        for waiter in waiters {
            waiter.timeoutTask.cancel()
            waiter.continuation.resume(throwing: error)
        }
        let accountWaiters = loginWaiters.values
        loginWaiters.removeAll()
        bufferedLoginOutcomes.removeAll()
        bufferedLoginOutcomeOrder.removeAll()
        ignoredLoginIDs.removeAll()
        for waiter in accountWaiters {
            waiter.resume(throwing: error)
        }
        let subscribers = turnSubscribers.values.flatMap(\.values)
        turnSubscribers.removeAll()
        subscribers.forEach { $0.finish(throwing: error) }
        await currentTransport?.close()
    }

    private func failRequest(_ requestID: Int, error: any Error) {
        pendingRequests.removeValue(forKey: requestID)?.continuation.resume(throwing: error)
    }

    private func cancelRequest(_ requestID: Int) {
        pendingRequests.removeValue(forKey: requestID)?.continuation.resume(throwing: CancellationError())
    }

    private func cancelTurnWaiter(_ key: TurnKey) {
        guard let waiter = turnWaiters.removeValue(forKey: key) else { return }
        waiter.timeoutTask.cancel()
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func cancelLoginWaiter(_ loginID: String) {
        loginWaiters.removeValue(forKey: loginID)?.resume(throwing: CancellationError())
        bufferedLoginOutcomes.removeValue(forKey: loginID)
        bufferedLoginOutcomeOrder.removeAll { $0 == loginID }
    }

    private func cancelLoginAfterWaiterCancellation(_ loginID: String) async {
        ignoredLoginIDs.insert(loginID)
        cancelLoginWaiter(loginID)
        guard !isShuttingDown, isInitialized, transport != nil else { return }
        _ = try? await requestOnCurrentConnection(
            method: "account/login/cancel",
            params: .object(["loginId": .string(loginID)]),
            timeout: transportTimeout
        )
    }

    private func configReadResult() async throws -> JSONValue {
        if let cachedConfigReadResult { return cachedConfigReadResult }
        let result = try await request(method: "config/read")
        cachedConfigReadResult = result
        return result
    }

    private func requireCurrentConfiguration() async throws {
        guard await configurationReadiness() else {
            throw CodexConfigurationError.accountNotReady
        }
    }

    private func timeoutTurnWaiter(_ key: TurnKey) {
        guard let waiter = turnWaiters.removeValue(forKey: key) else { return }
        waiter.continuation.resume(throwing: CodexAppServerError.requestTimedOut("summary"))
    }

    private func removeTurnSubscriber(_ subscriberID: UUID, for key: TurnKey) {
        turnSubscribers[key]?.removeValue(forKey: subscriberID)
        if turnSubscribers[key]?.isEmpty == true {
            turnSubscribers.removeValue(forKey: key)
        }
    }

    private func finishTurnSubscribers(for key: TurnKey) {
        guard let subscribers = turnSubscribers.removeValue(forKey: key)?.values else { return }
        subscribers.forEach { $0.finish() }
    }

    private func waitForStartup() async throws {
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    startupWaiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelStartupWaiter(waiterID) }
        }
    }

    private func cancelStartupWaiter(_ waiterID: UUID) {
        startupWaiters.removeValue(forKey: waiterID)?.resume(throwing: CancellationError())
    }

    private func waitForGenerationsToFinish() async throws {
        guard !generations.isEmpty else { return }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if generations.isEmpty {
                    continuation.resume()
                } else {
                    generationDrainWaiters[waiterID] = continuation
                    #if DEBUG
                        let testWaiters = generationDrainTestWaiters
                        generationDrainTestWaiters.removeAll()
                        testWaiters.forEach { $0.resume() }
                    #endif
                }
            }
        } onCancel: {
            Task { await self.cancelGenerationDrainWaiter(waiterID) }
        }
    }

    private func cancelGenerationDrainWaiter(_ waiterID: UUID) {
        generationDrainWaiters.removeValue(forKey: waiterID)?.resume(throwing: CancellationError())
    }

    private func resumeGenerationDrainWaitersIfIdle() {
        guard generations.isEmpty else { return }
        resumeGenerationDrainWaiters()
    }

    private func resumeGenerationDrainWaiters(throwing error: (any Error)? = nil) {
        let waiters = generationDrainWaiters.values
        generationDrainWaiters.removeAll()
        for waiter in waiters {
            if let error {
                waiter.resume(throwing: error)
            } else {
                waiter.resume()
            }
        }
    }

    private func interruptGeneration(_ generationID: UUID) async {
        guard let context = generations[generationID],
              !context.didSendInterrupt,
              let key = context.key
        else { return }
        generations[generationID]?.didSendInterrupt = true
        guard !isShuttingDown, isInitialized, transport != nil else { return }
        _ = try? await requestOnCurrentConnection(
            method: "turn/interrupt",
            params: .object([
                "threadId": .string(key.threadID),
                "turnId": .string(key.turnID),
            ]),
            timeout: transportTimeout
        )
    }

    private func resumeStartupWaiters(throwing error: (any Error)? = nil) {
        let waiters = startupWaiters.values
        startupWaiters.removeAll()
        for waiter in waiters {
            if let error {
                waiter.resume(throwing: error)
            } else {
                waiter.resume()
            }
        }
    }

    private func waitForConnectionStop() async {
        guard isStoppingConnection else { return }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    connectionStopWaiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelConnectionStopWaiter(waiterID) }
        }
    }

    private func cancelConnectionStopWaiter(_ waiterID: UUID) {
        connectionStopWaiters.removeValue(forKey: waiterID)?.resume()
    }

    private func resumeConnectionStopWaiters() {
        let waiters = connectionStopWaiters.values
        connectionStopWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func decode<T: Decodable>(_ value: JSONValue) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    private static func isSummaryTimeout(_ error: any Error) -> Bool {
        guard case let CodexAppServerError.requestTimedOut(operation) = error else { return false }
        return operation == "summary"
    }

    private static func resume(
        _ continuation: CheckedContinuation<Void, any Error>,
        with outcome: LoginOutcome
    ) {
        switch outcome {
        case .succeeded:
            continuation.resume()
        case let .failed(detail):
            continuation.resume(throwing: CodexAppServerError.loginFailed(detail))
        }
    }

    private struct ModelListResponse: Decodable {
        let data: [CodexModel]
        let nextCursor: String?
    }
}

#if DEBUG
    extension CodexAppServerService {
        func waitUntilActiveTurnForTesting() async {
            if generations.values.contains(where: { $0.key != nil }) { return }
            await withCheckedContinuation { continuation in
                activeTurnTestWaiters.append(continuation)
            }
        }

        func waitUntilActiveTurnCountForTesting(_ count: Int) async throws {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(10))
            while generations.values.count(where: { $0.key != nil }) < count {
                guard clock.now < deadline else {
                    throw CodexAppServerError.requestTimedOut("active turn test wait")
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        func waitUntilConfigurationReloadIsWaitingForTesting() async {
            if !generationDrainWaiters.isEmpty { return }
            await withCheckedContinuation { continuation in
                generationDrainTestWaiters.append(continuation)
            }
        }
    }
#endif
