// JSON-RPC lifecycle and protocol handlers remain colocated behind one actor boundary.
// swiftlint:disable file_length

import DahliaRuntimeSupport
import Foundation
import OSLog

actor CodexAppServerService {
    nonisolated static let defaultTransportTimeout = Duration.seconds(30)
    nonisolated static let defaultSummaryTimeout = Duration.seconds(610)
    private nonisolated static let turnRecoveryTimeout = Duration.seconds(15)

    typealias TransportFactory = @Sendable () throws -> any CodexAppServerTransport
    typealias ConfigurationReadiness = @Sendable () async -> Bool
    typealias AccountProviderResolver = @Sendable () async -> AIAccountProvider?
    typealias ProviderAuthenticationPreparation = @Sendable (
        _ provider: CodexRuntimeProvider,
        _ authenticationMayChange: @Sendable () async -> Void
    ) async throws -> Bool
    typealias RuntimeProviderResolver = @Sendable () -> CodexRuntimeProvider

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
        var continuation: CheckedContinuation<JSONValue, any Error>?
        let lateChatTurnStartThreadID: String?
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

    private enum ApprovalResponseKind {
        case decision
        case mcpToolCall(questionID: String)
        case userInput(questionID: String)
    }

    private struct PendingApprovalResponse {
        let requestID: JSONValue
        let responseKind: ApprovalResponseKind
    }

    private struct PendingApproval {
        let requestID: JSONValue
        let responseKind: ApprovalResponseKind
        let key: TurnKey
        let pendingStartID: UUID?
    }

    private struct PendingChatTurnStart {
        let threadID: String
        var turnID: String?
        var bufferedKeys: Set<TurnKey> = []
    }

    private struct ChatTurnRuntime {
        enum Phase {
            case starting
            case active
            case stopping
        }

        let generation: Int
        let threadID: String
        let requestID: Int
        var turnID: String?
        var phase: Phase
        var pendingApprovals: [String: PendingApprovalResponse] = [:]
        var respondedApprovalIDs: Set<String> = []
        let continuation: AsyncThrowingStream<CodexAppServerChatTurnEvent, any Error>.Continuation
        var timeoutTask: Task<Void, Never>?
        var didSendInterrupt = false
        var stopWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    }

    private struct DiscoveredChatTurnStop {
        let generation: Int
        let timeoutTask: Task<Void, Never>
    }

    private struct GenerationContext {
        var threadID: String?
        var key: TurnKey?
        var temporaryDirectory: URL?
        var didSendInterrupt = false
    }

    struct ProviderAuthenticationPreparationState {
        let id: UUID
        let provider: CodexRuntimeProvider
        let task: Task<Void, Error>
        var waiters: Set<UUID>
    }

    private enum LoginOutcome {
        case succeeded
        case failed(String?)
    }

    private let transportFactory: TransportFactory
    private let configurationReadiness: ConfigurationReadiness
    private let accountProviderResolver: AccountProviderResolver
    let runtimeProviderResolver: RuntimeProviderResolver
    private let clock: any CodexAppServerClock
    private let transportTimeout: Duration
    private let summaryTimeout: Duration
    private let chatTurnEventBufferLimit = 32
    let providerAuthenticationPreparation: ProviderAuthenticationPreparation
    private let logger = Logger(subsystem: "com.dahlia", category: "CodexAppServer")
    private var transport: (any CodexAppServerTransport)?
    private var readerTask: Task<Void, Never>?
    private var connectionGeneration = 0
    private var nextRequestID = 1
    private var pendingRequests: [Int: PendingRequest] = [:]
    private var turnWaiters: [TurnKey: TurnWaiter] = [:]
    private var turnSubscribers: [TurnKey: [UUID: AsyncThrowingStream<JSONValue, any Error>.Continuation]] = [:]
    private var activeChatTurnIDs: [String: String] = [:]
    private var bufferedTurnMessages: [TurnKey: [JSONValue]] = [:]
    private var chatThreadIDs: Set<String> = []
    private var chatThreadLeases: [String: Set<UUID>] = [:]
    private var pendingApprovals: [String: PendingApproval] = [:]
    private var startupWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var generations: [UUID: GenerationContext] = [:]
    private var generationDrainWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var activeCodexOperations: Set<UUID> = []
    private var codexOperationDrainWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var pendingChatTurnStarts: [UUID: PendingChatTurnStart] = [:]
    private var chatTurnRuntimes: [UUID: ChatTurnRuntime] = [:]
    private var discoveredChatTurnStops: [TurnKey: DiscoveredChatTurnStop] = [:]
    private var retiredChatTurnKeys: Set<TurnKey> = []
    private var retiredChatTurnOrder: [TurnKey] = []
    private var chatTurnDrainWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var configurationReloadWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var cachedModels: [CodexModel]?
    private var cachedAccountStatus: AccountStatus?
    private var cachedConfigReadResult: JSONValue?
    private var loginWaiters: [String: CheckedContinuation<Void, any Error>] = [:]
    private var bufferedLoginOutcomes: [String: LoginOutcome] = [:]
    private var bufferedLoginOutcomeOrder: [String] = []
    private var ignoredLoginIDs: Set<String> = []
    private var isStarting = false
    private var isStoppingConnection = false
    private var isConfigurationReloading = false
    private var connectionStopWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var isInitialized = false
    var isShuttingDown = false
    var providerAuthenticationReloadRequired = false
    var providerAuthenticationPreparationState: ProviderAuthenticationPreparationState?
    #if DEBUG
        private var activeTurnTestWaiters: [CheckedContinuation<Void, Never>] = []
        private var generationDrainTestWaiters: [CheckedContinuation<Void, Never>] = []
        private var chatTurnDrainTestWaiters: [CheckedContinuation<Void, Never>] = []
    #endif

    init(
        launcher: BundledCodexAppServerLauncher = BundledCodexAppServerLauncher(),
        clock: any CodexAppServerClock = ContinuousCodexAppServerClock(),
        transportTimeout: Duration = CodexAppServerService.defaultTransportTimeout,
        summaryTimeout: Duration = CodexAppServerService.defaultSummaryTimeout,
        providerAuthenticationPreparation: @escaping ProviderAuthenticationPreparation =
            CodexAppServerService.prepareConfiguredDatabricksAuthentication,
        configurationReadiness: @escaping ConfigurationReadiness = {
            await VaultAISettingsModel.shared.waitForRuntimeContext()
        },
        accountProviderResolver: @escaping AccountProviderResolver = {
            CodexRuntimeContextStore.shared.provider.localAccountProvider
        },
        runtimeProviderResolver: @escaping RuntimeProviderResolver = {
            CodexRuntimeContextStore.shared.provider
        }
    ) {
        transportFactory = { try launcher.launch() }
        self.configurationReadiness = configurationReadiness
        self.accountProviderResolver = accountProviderResolver
        self.clock = clock
        self.transportTimeout = transportTimeout
        self.summaryTimeout = summaryTimeout
        self.providerAuthenticationPreparation = providerAuthenticationPreparation
        self.runtimeProviderResolver = runtimeProviderResolver
    }

    init(
        transportFactory: @escaping TransportFactory,
        clock: any CodexAppServerClock = ContinuousCodexAppServerClock(),
        transportTimeout: Duration = CodexAppServerService.defaultTransportTimeout,
        summaryTimeout: Duration = CodexAppServerService.defaultSummaryTimeout,
        providerAuthenticationPreparation: @escaping ProviderAuthenticationPreparation = { _, _ in false },
        configurationReadiness: @escaping ConfigurationReadiness = { true },
        accountProviderResolver: @escaping AccountProviderResolver = { nil },
        runtimeProviderResolver: @escaping RuntimeProviderResolver = { .chatGPTSubscription }
    ) {
        self.transportFactory = transportFactory
        self.configurationReadiness = configurationReadiness
        self.accountProviderResolver = accountProviderResolver
        self.clock = clock
        self.transportTimeout = transportTimeout
        self.summaryTimeout = summaryTimeout
        self.providerAuthenticationPreparation = providerAuthenticationPreparation
        self.runtimeProviderResolver = runtimeProviderResolver
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

    func configuredAccountProvider() async -> AIAccountProvider? {
        await accountProviderResolver()
    }

    func shutdown() async {
        isShuttingDown = true
        providerAuthenticationPreparationState?.task.cancel()
        providerAuthenticationPreparationState = nil
        cachedModels = nil
        cachedAccountStatus = nil
        await stopConnection(error: CancellationError())
        resumeStartupWaiters(throwing: CancellationError())
        resumeGenerationDrainWaiters(throwing: CancellationError())
        resumeCodexOperationDrainWaiters(throwing: CancellationError())
        resumeChatTurnDrainWaiters(throwing: CancellationError())
        resumeConfigurationReloadWaiters(throwing: CancellationError())
        isStarting = false
    }

    func reloadConfiguration(
        applyingContext: (@Sendable () -> Void)? = nil
    ) async throws {
        guard !isShuttingDown else { throw CancellationError() }
        if isConfigurationReloading {
            do {
                try await waitForConfigurationReloadToFinish()
            } catch is CancellationError {
                guard !Task.isCancelled, applyingContext != nil else { throw CancellationError() }
            }
            if let applyingContext {
                try await reloadConfiguration(applyingContext: applyingContext)
            }
            return
        }

        isConfigurationReloading = true
        do {
            try await waitForCodexOperationsToFinish()
            try await waitForGenerationsToFinish()
            try await waitForChatTurnsToFinish()
            await stopConnection(error: CancellationError())
            try Task.checkCancellation()
            applyingContext?()
            cachedModels = nil
            cachedAccountStatus = nil
            cachedConfigReadResult = nil
            try await start()
            providerAuthenticationReloadRequired = false
            finishConfigurationReload()
        } catch {
            finishConfigurationReload(throwing: error)
            throw error
        }
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
        bypassConfigurationCheck: Bool = false,
        bypassProviderAuthenticationPreparation: Bool = false,
        bypassConfigurationReloadAdmission: Bool = false
    ) async throws -> [CodexModel] {
        if !bypassConfigurationCheck {
            try await requireCurrentConfiguration()
        }
        let runtimeProvider = runtimeProviderResolver()
        if !bypassProviderAuthenticationPreparation {
            try await prepareProviderAuthentication(for: runtimeProvider)
        }
        if !bypassConfigurationCheck {
            try await requireCurrentConfiguration()
        }
        let operationID = try await beginCodexOperation(
            bypassingAdmission: bypassConfigurationReloadAdmission
        )
        defer { finishCodexOperation(operationID) }
        guard runtimeProviderResolver() == runtimeProvider else {
            throw CodexConfigurationError.providerChanged(runtimeProvider.displayName)
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
                "type": .string("chatgpt"),
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

    /// Stable identifier for a server request whose JSON-RPC `id` may be a string or a number.
    nonisolated static func approvalID(for id: JSONValue) -> String? {
        switch id {
        case let .string(value): "s:\(value)"
        case let .number(value): "n:\(value)"
        default: nil
        }
    }

    func respondToApproval(id: String, decision: CodexChatApprovalDecision) async {
        guard let approval = pendingApprovals.removeValue(forKey: id) else { return }
        do {
            try await sendApprovalResponse(
                requestID: approval.requestID,
                kind: approval.responseKind,
                decision: decision
            )
        } catch {
            await stopConnection(error: error)
        }
    }

    func prepareChatTurnForInterrupt(threadID: String, turnID: String?) async -> String? {
        if let localTurnID = chatTurnRuntimes.first(where: { _, runtime in
            runtime.threadID == threadID
                && (turnID == nil || runtime.turnID == turnID)
        })?.key {
            await cancelPendingApprovals(localTurnID)
            return chatTurnRuntimes[localTurnID]?.turnID
        }
        guard let turnID = turnID ?? activeChatTurnIDs[threadID] else { return nil }
        let key = TurnKey(threadID: threadID, turnID: turnID)
        await resolvePendingApprovals(for: key, decision: .cancel)
        return turnID
    }

    func forgetChatThread(_ threadID: String) {
        chatThreadIDs.remove(threadID)
    }

    func acquireChatThreadLease(_ threadID: String) -> UUID {
        let leaseID = UUID.v7()
        chatThreadLeases[threadID, default: []].insert(leaseID)
        return leaseID
    }

    /// Returns true when the caller released the final owner. A final release also ends the server subscription.
    func releaseChatThreadLease(_ threadID: String, leaseID: UUID) async -> Bool {
        guard chatThreadLeases[threadID]?.remove(leaseID) != nil else { return false }
        if chatThreadLeases[threadID]?.isEmpty == false {
            return false
        }
        chatThreadLeases.removeValue(forKey: threadID)
        chatThreadIDs.remove(threadID)
        guard isInitialized, transport != nil else { return true }
        _ = try? await requestOnCurrentConnection(
            method: "thread/unsubscribe",
            params: .object(["threadId": .string(threadID)]),
            timeout: transportTimeout
        )
        return true
    }

    func startChatTurn(
        threadID: String,
        params: JSONValue
    ) async throws -> (turnID: String, notifications: AsyncThrowingStream<JSONValue, any Error>) {
        try await waitForConfigurationReloadToFinish()
        guard discoveredChatTurnStops.keys.allSatisfy({ $0.threadID != threadID }) else {
            throw CodexAppServerError.rpcError(code: nil, message: "A chat turn is already stopping for this thread")
        }
        // Registered before the request so an approval request that arrives ahead of the
        // turn/start response is still recognized as a chat thread.
        chatThreadIDs.insert(threadID)
        let startID = UUID()
        pendingChatTurnStarts[startID] = PendingChatTurnStart(threadID: threadID)
        defer {
            pendingChatTurnStarts.removeValue(forKey: startID)
            resumeChatTurnDrainWaitersIfIdle()
        }
        do {
            try await start()
            let generation = connectionGeneration
            let result = try await requestOnCurrentConnection(
                method: "turn/start",
                params: params,
                timeout: transportTimeout,
                lateChatTurnStartThreadID: threadID
            )
            guard generation == connectionGeneration else { throw CancellationError() }
            guard let turnID = result.objectValue?["turn"]?.objectValue?["id"]?.stringValue else {
                throw CodexAppServerError.invalidProtocolResponse
            }
            let key = TurnKey(threadID: threadID, turnID: turnID)
            if Task.isCancelled {
                pendingChatTurnStarts[startID]?.bufferedKeys.insert(key)
                throw CancellationError()
            }
            activeChatTurnIDs[threadID] = turnID
            await reconcilePendingChatTurnStart(
                startID,
                with: key
            )
            return (turnID, notifications(threadID: threadID, turnID: turnID))
        } catch {
            await cleanUpFailedChatTurnStart(startID)
            throw error
        }
    }

    func beginChatTurn(
        threadID: String,
        params: JSONValue,
        bypassConfigurationReloadAdmission: Bool = false
    ) async throws -> CodexAppServerChatTurn {
        if !bypassConfigurationReloadAdmission {
            try await waitForConfigurationReloadToFinish()
        }
        try await start()
        guard chatTurnRuntimes.values.allSatisfy({ $0.threadID != threadID }),
              discoveredChatTurnStops.keys.allSatisfy({ $0.threadID != threadID })
        else {
            throw CodexAppServerError.rpcError(code: nil, message: "A chat turn is already active for this thread")
        }

        let localTurnID = UUID.v7()
        let requestID = nextRequestID
        nextRequestID += 1
        let generation = connectionGeneration
        let (stream, continuation) = AsyncThrowingStream<CodexAppServerChatTurnEvent, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(chatTurnEventBufferLimit)
        )
        continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination else { return }
            Task { await self?.stopChatTurn(localTurnID) }
        }
        chatTurnRuntimes[localTurnID] = ChatTurnRuntime(
            generation: generation,
            threadID: threadID,
            requestID: requestID,
            phase: .starting,
            continuation: continuation
        )
        let timeoutTask = Task { [weak self, clock, transportTimeout] in
            do {
                try await clock.sleep(for: transportTimeout)
                await self?.chatTurnStartTimedOut(localTurnID, generation: generation)
            } catch {
                // Runtime completion cancels its owned timeout.
            }
        }
        chatTurnRuntimes[localTurnID]?.timeoutTask = timeoutTask

        var turnParams = params.objectValue ?? [:]
        turnParams["clientUserMessageId"] = .string(localTurnID.uuidString)
        do {
            try await sendMessage(.object([
                "id": .number(Double(requestID)),
                "method": .string("turn/start"),
                "params": .object(turnParams),
            ]))
        } catch {
            // A failed write may still have reached the helper. Without a server turn ID,
            // replacing the connection is the only way to ensure that turn cannot continue.
            if generation == connectionGeneration {
                await stopConnection(error: CodexAppServerError.backendResetForSafety)
            } else {
                finishChatTurn(localTurnID, throwing: error)
            }
            throw error
        }
        return CodexAppServerChatTurn(id: localTurnID, events: stream)
    }

    func decideChatApproval(
        turnID: UUID,
        approvalID: String,
        decision: CodexChatApprovalDecision
    ) async throws {
        guard let runtime = chatTurnRuntimes[turnID],
              runtime.generation == connectionGeneration,
              let approval = runtime.pendingApprovals[approvalID]
        else { throw CodexAppServerError.approvalNoLongerPending }
        chatTurnRuntimes[turnID]?.pendingApprovals.removeValue(forKey: approvalID)
        chatTurnRuntimes[turnID]?.respondedApprovalIDs.insert(approvalID)
        do {
            try await sendApprovalResponse(
                requestID: approval.requestID,
                kind: approval.responseKind,
                decision: decision
            )
        } catch {
            if runtime.generation == connectionGeneration {
                await stopConnection(error: error)
            }
            throw error
        }
    }

    func respondToChatUserInput(
        turnID: UUID,
        requestID: String,
        answer: String
    ) async throws {
        guard let runtime = chatTurnRuntimes[turnID],
              runtime.generation == connectionGeneration,
              let pending = runtime.pendingApprovals[requestID],
              case let .userInput(questionID) = pending.responseKind
        else { throw CodexAppServerError.approvalNoLongerPending }
        chatTurnRuntimes[turnID]?.pendingApprovals.removeValue(forKey: requestID)
        chatTurnRuntimes[turnID]?.respondedApprovalIDs.insert(requestID)
        do {
            try await sendUserInputResponse(
                requestID: pending.requestID,
                questionID: questionID,
                answer: answer
            )
        } catch {
            if runtime.generation == connectionGeneration {
                await stopConnection(error: error)
            }
            throw error
        }
    }

    private func sendApprovalResponse(
        requestID: JSONValue,
        kind: ApprovalResponseKind,
        decision: CodexChatApprovalDecision
    ) async throws {
        switch kind {
        case .decision:
            try await sendMessage(.object([
                "id": requestID,
                "result": .object(["decision": decision.jsonValue]),
            ]))
        case let .mcpToolCall(questionID):
            let answer = if decision == .accept {
                "Allow"
            } else {
                "Cancel"
            }
            try await sendUserInputResponse(
                requestID: requestID,
                questionID: questionID,
                answer: answer
            )
        case .userInput:
            try await sendMessage(.object([
                "id": requestID,
                "result": .object(["answers": .object([:])]),
            ]))
        }
    }

    private func sendUserInputResponse(
        requestID: JSONValue,
        questionID: String,
        answer: String
    ) async throws {
        try await sendMessage(.object([
            "id": requestID,
            "result": .object([
                "answers": .object([
                    questionID: .object(["answers": .array([.string(answer)])]),
                ]),
            ]),
        ]))
    }

    func stopChatTurn(_ localTurnID: UUID) async {
        guard var runtime = chatTurnRuntimes[localTurnID] else { return }
        runtime.phase = .stopping
        runtime.timeoutTask?.cancel()
        runtime.timeoutTask = nil
        chatTurnRuntimes[localTurnID] = runtime

        for approvalID in runtime.pendingApprovals.keys {
            try? await decideChatApproval(
                turnID: localTurnID,
                approvalID: approvalID,
                decision: .cancel
            )
        }

        guard let currentRuntime = chatTurnRuntimes[localTurnID],
              currentRuntime.generation == runtime.generation else { return }
        guard let turnID = currentRuntime.turnID else {
            await stopConnection(error: CodexAppServerError.backendResetForSafety)
            return
        }
        guard chatTurnRuntimes[localTurnID]?.didSendInterrupt == false else {
            await waitForChatTurnToFinish(localTurnID)
            return
        }
        chatTurnRuntimes[localTurnID]?.didSendInterrupt = true
        do {
            try await sendChatTurnInterrupt(runtime: runtime, turnID: turnID)
        } catch {
            if chatTurnRuntimes[localTurnID]?.generation == runtime.generation,
               runtime.generation == connectionGeneration {
                await stopConnection(error: CodexAppServerError.backendResetForSafety)
            }
            return
        }
        armChatTurnStopTimeout(localTurnID, generation: runtime.generation)
        await waitForChatTurnToFinish(localTurnID)
    }

    // swiftformat:disable:next modifierOrder
    private nonisolated static func isTurnCompletionMessage(_ message: JSONValue) -> Bool {
        message.objectValue?["method"]?.stringValue == "turn/completed"
    }

    func chatThreadConfiguration(
        reasoningEffort: String,
        vaultID: UUID,
        helperURL: URL,
        bypassConfigurationReloadAdmission: Bool = false
    ) async throws -> JSONValue {
        try await requireCurrentConfiguration()
        let operationID = try await beginCodexOperation(
            bypassingAdmission: bypassConfigurationReloadAdmission
        )
        defer { finishCodexOperation(operationID) }
        let configuration = try await configReadResult()
        return try Self.chatThreadConfig(
            from: configuration,
            reasoningEffort: reasoningEffort,
            helperURL: helperURL,
            vaultID: vaultID
        )
    }

    func chatRequest(
        method: String,
        params: JSONValue,
        bypassConfigurationReloadAdmission: Bool = false
    ) async throws -> JSONValue {
        let operationID = try await beginCodexOperation(
            bypassingAdmission: bypassConfigurationReloadAdmission
        )
        defer { finishCodexOperation(operationID) }
        return try await request(method: method, params: params)
    }

    func withChatOperation<Result: Sendable>(
        expectedProvider: CodexRuntimeProvider? = nil,
        _ operation: @Sendable (isolated CodexAppServerService) async throws -> Result
    ) async throws -> Result {
        try await requireCurrentConfiguration()
        let runtimeProvider = runtimeProviderResolver()
        if let expectedProvider, expectedProvider != runtimeProvider {
            throw CodexConfigurationError.providerChanged(expectedProvider.displayName)
        }
        try await prepareProviderAuthentication(for: runtimeProvider)
        try await requireCurrentConfiguration()
        let operationID = try await beginCodexOperation()
        defer { finishCodexOperation(operationID) }
        guard runtimeProviderResolver() == runtimeProvider else {
            throw CodexConfigurationError.providerChanged(runtimeProvider.displayName)
        }
        return try await operation(self)
    }

    func generate(
        _ request: CodexAppServerRequest,
        bypassConfigurationCheck: Bool = false,
        retryDahliaAuthentication: Bool = true,
        expectedProvider: CodexRuntimeProvider? = nil
    ) async throws -> String {
        if !bypassConfigurationCheck {
            try await requireCurrentConfiguration()
        }
        let runtimeProvider = runtimeProviderResolver()
        guard expectedProvider == nil || expectedProvider == runtimeProvider else {
            throw CodexConfigurationError.accountNotReady
        }
        try await prepareProviderAuthentication(for: runtimeProvider)
        if !bypassConfigurationCheck {
            try await requireCurrentConfiguration()
        }
        try await waitForConfigurationReloadToFinish()
        guard runtimeProviderResolver() == runtimeProvider else {
            throw CodexConfigurationError.accountNotReady
        }
        let generationID = UUID()
        generations[generationID] = GenerationContext()

        do {
            let result = try await performGeneration(request, generationID: generationID)
            await finishGeneration(generationID)
            return result
        } catch {
            if error is CancellationError || Task.isCancelled {
                let cleanup = Task {
                    await finishGeneration(generationID, interrupt: true)
                }
                await cleanup.value
                throw CancellationError()
            }
            await finishGeneration(
                generationID,
                interrupt: Self.isSummaryTimeout(error)
            )
            if retryDahliaAuthentication,
               error as? CodexAppServerError == .notLoggedIn,
               case let .dahlia(connectionID) = runtimeProvider {
                _ = try await DahliaCloudTokenServiceRegistry.shared.validAccessToken(
                    connectionID: connectionID,
                    forceRefresh: true
                )
                guard runtimeProviderResolver() == runtimeProvider else { throw error }
                try await reloadConfiguration()
                return try await generate(
                    request,
                    bypassConfigurationCheck: bypassConfigurationCheck,
                    retryDahliaAuthentication: false,
                    expectedProvider: runtimeProvider
                )
            }
            throw error
        }
    }

    nonisolated static func summaryThreadConfig(
        from configReadResult: JSONValue,
        reasoningEffort: String = CodexReasoningEffortOption.defaultValue
    ) throws -> JSONValue {
        try restrictedThreadConfig(
            from: configReadResult,
            reasoningEffort: reasoningEffort
        )
    }

    nonisolated static func chatThreadConfig(
        from configReadResult: JSONValue,
        reasoningEffort: String = CodexReasoningEffortOption.defaultValue,
        helperURL: URL,
        vaultID: UUID,
        runtimeProfile: DahliaRuntimeProfile = DahliaApplicationSupport.profile()
    ) throws -> JSONValue {
        guard case var .object(config) = try restrictedThreadConfig(
            from: configReadResult,
            reasoningEffort: reasoningEffort
        ) else {
            throw CodexAppServerError.invalidProtocolResponse
        }
        var servers = config["mcp_servers"]?.objectValue ?? [:]
        servers["dahlia"] = dahliaChatMCPServer(
            executableURL: helperURL,
            vaultID: vaultID,
            runtimeProfile: runtimeProfile
        )
        config["mcp_servers"] = .object(servers)
        config["features.default_mode_request_user_input"] = .bool(true)
        config["features.tool_call_mcp_elicitation"] = .bool(false)
        config["skills.include_instructions"] = .bool(true)
        config["web_search"] = .string("live")
        return .object(config)
    }

    private nonisolated static func dahliaChatMCPServer(
        executableURL: URL,
        vaultID: UUID,
        runtimeProfile: DahliaRuntimeProfile
    ) -> JSONValue {
        let command: String
        let invocationArguments: [JSONValue]
        switch runtimeProfile {
        case .production:
            command = executableURL.path
            invocationArguments = []
        case .development:
            command = "/usr/bin/env"
            invocationArguments = [
                .string("\(DahliaApplicationSupport.profileEnvironmentKey)=\(runtimeProfile.rawValue)"),
                .string(executableURL.path),
            ]
        }
        return .object([
            "args": .array(invocationArguments + [
                .string("--vault-id"),
                .string(vaultID.uuidString),
                .string("--write"),
                .string("--telemetry-origin"),
                .string("codexChat"),
            ]),
            "command": .string(command),
            "enabled": .bool(true),
        ])
    }

    // swiftformat:disable:next modifierOrder
    private nonisolated static func restrictedThreadConfig(
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
            "skills.bundled.enabled": .bool(false),
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
        if runtimeProviderResolver() == .chatGPTSubscription {
            let accountResult = try await requestOnCurrentConnection(
                method: "account/read",
                params: .object(["refreshToken": .bool(false)]),
                timeout: transportTimeout
            )
            cachedAccountStatus = try Self.parseAccountStatus(accountResult)
        } else {
            cachedAccountStatus = AccountStatus(isAuthenticated: false, requiresOpenAIAuth: false, label: nil)
        }
    }

    private func performGeneration(
        _ request: CodexAppServerRequest,
        generationID: UUID
    ) async throws -> String {
        try await start()
        try Task.checkCancellation()

        let account = try await accountStatus(forceRefresh: false)
        guard account.canUseCodex else { throw CodexAppServerError.notLoggedIn }
        let availableModels = try await models(
            bypassProviderAuthenticationPreparation: true,
            bypassConfigurationReloadAdmission: true
        )
        var selectedModel = request.model
            .flatMap { requestedModel in availableModels.first { $0.model == requestedModel } }
            ?? availableModels.first(where: \CodexModel.isDefault)
        if request.requiresExactModel,
           selectedModel?.model != request.model {
            let refreshedModels = try await models(
                forceRefresh: true,
                bypassProviderAuthenticationPreparation: true,
                bypassConfigurationReloadAdmission: true
            )
            selectedModel = request.model
                .flatMap { requestedModel in refreshedModels.first { $0.model == requestedModel } }
                ?? refreshedModels.first(where: \CodexModel.isDefault)
        }
        if request.requiresExactModel,
           selectedModel?.model != request.model,
           let requestedModel = request.model {
            throw CodexAppServerError.requestedModelUnavailable(requestedModel)
        }
        if request.requiresImageInput,
           let selectedModel,
           !selectedModel.supportsImages {
            throw CodexAppServerError.requestedModelUnavailable(selectedModel.model)
        }
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
                reasoningEffort: request.reasoningEffort
            ),
            "cwd": .string(temporaryDirectory.path),
            "developerInstructions": .string(request.developerInstructions + Self.summaryToolInstruction),
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

    private nonisolated static let summaryToolInstruction = "\nDo not call tools. Return only the requested JSON."

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
        timeout: Duration,
        lateChatTurnStartThreadID: String? = nil
    ) async throws -> JSONValue {
        guard transport != nil else { throw CodexAppServerError.processExited(nil) }
        let requestID = nextRequestID
        nextRequestID += 1

        return try await withThrowingTaskGroup(of: JSONValue.self) { group in
            group.addTask {
                try await self.awaitResponse(
                    requestID: requestID,
                    method: method,
                    params: params,
                    lateChatTurnStartThreadID: lateChatTurnStartThreadID
                )
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
        params: JSONValue,
        lateChatTurnStartThreadID: String?
    ) async throws -> JSONValue {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pendingRequests[requestID] = PendingRequest(
                    method: method,
                    continuation: continuation,
                    lateChatTurnStartThreadID: lateChatTurnStartThreadID
                )
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
            try await handleServerRequest(
                id: requestID,
                method: method,
                params: object["params"]?.objectValue,
                message: message
            )
            return
        }

        if let requestID = object["id"]?.intValue {
            if let localTurnID = chatTurnRuntimes.first(where: { $0.value.requestID == requestID })?.key {
                await handleChatTurnStartResponse(object, localTurnID: localTurnID)
                return
            }
            guard let pending = pendingRequests.removeValue(forKey: requestID) else { return }
            guard let continuation = pending.continuation else {
                if let threadID = pending.lateChatTurnStartThreadID {
                    await interruptLateChatTurnStartResponse(object, threadID: threadID)
                }
                return
            }
            if let error = object["error"]?.objectValue {
                let message = error["message"]?.stringValue ?? L10n.codexUnknownError
                let code = error["code"]?.intValue
                if Self.isAuthenticationRPCError(
                    data: error["data"],
                    message: message,
                    method: pending.method
                ) {
                    continuation.resume(throwing: CodexAppServerError.notLoggedIn)
                } else {
                    continuation.resume(throwing: CodexAppServerError.rpcError(
                        code: code,
                        message: message
                    ))
                }
            } else if let result = object["result"] {
                continuation.resume(returning: result)
            } else {
                continuation.resume(throwing: CodexAppServerError.invalidProtocolResponse)
            }
            return
        }

        guard object["method"]?.stringValue != nil else {
            throw CodexAppServerError.invalidProtocolResponse
        }
        if try handleAccountNotification(object) {
            return
        }
        if await routeChatTurnRuntimeMessage(message) {
            return
        }
        await routeTurnMessage(message)
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

    private func handleServerRequest(
        id: JSONValue,
        method: String,
        params: [String: JSONValue]?,
        message: JSONValue
    ) async throws {
        switch method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            if await routeChatApprovalRequest(
                id: id,
                params: params,
                message: message,
                responseKind: .decision
            ) {
                return
            }
            try await sendMessage(.object([
                "id": id,
                "result": .object(["decision": .string("decline")]),
            ]))
        case "applyPatchApproval", "execCommandApproval":
            try await sendMessage(.object([
                "id": id,
                "result": .object(["decision": .string("denied")]),
            ]))
        case "item/tool/requestUserInput":
            if let params,
               let prompt = CodexChatMCPApprovalPrompt(params: params) {
                let responseKind = ApprovalResponseKind.mcpToolCall(
                    questionID: prompt.questionID
                )
                if await routeChatApprovalRequest(
                    id: id,
                    params: params,
                    message: message,
                    responseKind: responseKind
                ) {
                    return
                }
                try await sendApprovalResponse(
                    requestID: id,
                    kind: responseKind,
                    decision: .cancel
                )
                return
            }
            if let params,
               let requestID = Self.approvalID(for: id),
               let request = CodexChatUserInputRequest(id: requestID, params: params),
               await routeChatApprovalRequest(
                   id: id,
                   params: params,
                   message: message,
                   responseKind: .userInput(questionID: request.questionID)
               ) {
                return
            }
            try await sendServerRequestError(
                id: id,
                code: -32000,
                message: "User input request denied"
            )
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

    private func routeChatApprovalRequest(
        id: JSONValue,
        params: [String: JSONValue]?,
        message: JSONValue,
        responseKind: ApprovalResponseKind
    ) async -> Bool {
        if await routeOwnedChatApprovalRequest(
            id: id,
            params: params,
            message: message,
            responseKind: responseKind
        ) {
            return true
        }
        return await registerChatApprovalRequest(
            id: id,
            params: params,
            message: message,
            responseKind: responseKind
        )
    }

    private func handleChatTurnStartResponse(
        _ object: [String: JSONValue],
        localTurnID: UUID
    ) async {
        guard let runtime = chatTurnRuntimes[localTurnID],
              runtime.generation == connectionGeneration else { return }
        if let error = object["error"]?.objectValue {
            let message = error["message"]?.stringValue ?? L10n.codexUnknownError
            await cancelPendingApprovals(localTurnID)
            finishChatTurn(
                localTurnID,
                throwing: CodexAppServerError.rpcError(
                    code: error["code"]?.intValue,
                    message: message
                )
            )
            return
        }
        guard let turnID = object["result"]?.objectValue?["turn"]?.objectValue?["id"]?.stringValue else {
            await stopConnection(error: CodexAppServerError.backendResetForSafety)
            return
        }
        guard await bindChatTurn(localTurnID, to: turnID) else {
            await stopConnection(error: CodexAppServerError.backendResetForSafety)
            return
        }
        chatTurnRuntimes[localTurnID]?.timeoutTask?.cancel()
        chatTurnRuntimes[localTurnID]?.timeoutTask = nil
        if chatTurnRuntimes[localTurnID]?.phase == .starting {
            chatTurnRuntimes[localTurnID]?.phase = .active
        }
    }

    private func routeOwnedChatApprovalRequest(
        id: JSONValue,
        params: [String: JSONValue]?,
        message: JSONValue,
        responseKind: ApprovalResponseKind
    ) async -> Bool {
        guard let params,
              let threadID = params["threadId"]?.stringValue,
              let turnID = params["turnId"]?.stringValue,
              let approvalID = Self.approvalID(for: id),
              let localTurnID = chatTurnRuntimeID(threadID: threadID, turnID: turnID)
        else { return false }
        guard await bindChatTurn(localTurnID, to: turnID) else {
            await stopConnection(error: CodexAppServerError.backendResetForSafety)
            return true
        }
        guard chatTurnRuntimes[localTurnID]?.pendingApprovals.count ?? 0 < 16 else {
            try? await sendApprovalResponse(
                requestID: id,
                kind: responseKind,
                decision: .cancel
            )
            await initiateChatTurnStopFromReader(localTurnID)
            return true
        }
        chatTurnRuntimes[localTurnID]?.pendingApprovals[approvalID] = PendingApprovalResponse(
            requestID: id,
            responseKind: responseKind
        )
        if chatTurnRuntimes[localTurnID]?.phase == .stopping {
            try? await decideChatApproval(
                turnID: localTurnID,
                approvalID: approvalID,
                decision: .cancel
            )
        } else {
            _ = await yieldChatTurnEvent(.message(message), to: localTurnID)
        }
        return true
    }

    private func routeChatTurnRuntimeMessage(_ message: JSONValue) async -> Bool {
        guard let object = message.objectValue,
              let method = object["method"]?.stringValue,
              let params = object["params"]?.objectValue else { return false }

        if method == "serverRequest/resolved" {
            guard let requestID = params["requestId"],
                  let threadID = params["threadId"]?.stringValue,
                  let approvalID = Self.approvalID(for: requestID),
                  let localTurnID = chatTurnRuntimes.first(where: { _, runtime in
                      runtime.threadID == threadID
                          && (runtime.pendingApprovals[approvalID] != nil
                              || runtime.respondedApprovalIDs.contains(approvalID))
                  })?.key else { return false }
            chatTurnRuntimes[localTurnID]?.pendingApprovals.removeValue(forKey: approvalID)
            chatTurnRuntimes[localTurnID]?.respondedApprovalIDs.remove(approvalID)
            _ = await yieldChatTurnEvent(.approvalResolved(id: approvalID), to: localTurnID)
            return true
        }

        guard let threadID = params["threadId"]?.stringValue else { return false }
        let turnID: String? = switch method {
        case "turn/started":
            params["turn"]?.objectValue?["id"]?.stringValue
        case "turn/completed":
            params["turn"]?.objectValue?["id"]?.stringValue
        default:
            params["turnId"]?.stringValue
        }
        guard let turnID,
              let localTurnID = chatTurnRuntimeID(threadID: threadID, turnID: turnID)
        else { return false }
        guard await bindChatTurn(localTurnID, to: turnID) else {
            await stopConnection(error: CodexAppServerError.backendResetForSafety)
            return true
        }
        if method == "turn/started" {
            chatTurnRuntimes[localTurnID]?.timeoutTask?.cancel()
            chatTurnRuntimes[localTurnID]?.timeoutTask = nil
            if chatTurnRuntimes[localTurnID]?.phase == .starting {
                chatTurnRuntimes[localTurnID]?.phase = .active
            }
        }
        _ = await yieldChatTurnEvent(.message(message), to: localTurnID)
        if method == "turn/completed" {
            let pendingApprovalIDs = chatTurnRuntimes[localTurnID].map {
                Array($0.pendingApprovals.keys)
            } ?? []
            for approvalID in pendingApprovalIDs {
                try? await decideChatApproval(
                    turnID: localTurnID,
                    approvalID: approvalID,
                    decision: .decline
                )
            }
            finishChatTurn(localTurnID)
        }
        return true
    }

    private func chatTurnRuntimeID(threadID: String, turnID: String) -> UUID? {
        guard !retiredChatTurnKeys.contains(TurnKey(threadID: threadID, turnID: turnID)) else {
            return nil
        }
        return chatTurnRuntimes.first { _, runtime in
            runtime.threadID == threadID && (runtime.turnID == nil || runtime.turnID == turnID)
        }?.key
    }

    private func cancelPendingApprovals(_ localTurnID: UUID) async {
        let approvalIDs = chatTurnRuntimes[localTurnID].map {
            Array($0.pendingApprovals.keys)
        } ?? []
        for approvalID in approvalIDs {
            try? await decideChatApproval(
                turnID: localTurnID,
                approvalID: approvalID,
                decision: .cancel
            )
        }
    }

    /// The reader cannot await an RPC response while it is the only task consuming responses.
    private func initiateChatTurnStopFromReader(_ localTurnID: UUID) async {
        guard var runtime = chatTurnRuntimes[localTurnID] else { return }
        runtime.phase = .stopping
        runtime.timeoutTask?.cancel()
        runtime.timeoutTask = nil
        chatTurnRuntimes[localTurnID] = runtime
        await cancelPendingApprovals(localTurnID)
        guard let turnID = chatTurnRuntimes[localTurnID]?.turnID else {
            await stopConnection(error: CodexAppServerError.backendResetForSafety)
            return
        }
        guard chatTurnRuntimes[localTurnID]?.didSendInterrupt == false else { return }
        chatTurnRuntimes[localTurnID]?.didSendInterrupt = true
        do {
            try await sendChatTurnInterrupt(runtime: runtime, turnID: turnID)
            armChatTurnStopTimeout(localTurnID, generation: runtime.generation)
        } catch {
            await stopConnection(error: CodexAppServerError.backendResetForSafety)
        }
    }

    /// A terminal notification, rather than the JSON-RPC acknowledgement, is the
    /// source of truth that interruption has completed.
    private func sendChatTurnInterrupt(
        runtime: ChatTurnRuntime,
        turnID: String
    ) async throws {
        try await sendTurnInterrupt(threadID: runtime.threadID, turnID: turnID)
    }

    private func sendTurnInterrupt(threadID: String, turnID: String) async throws {
        let requestID = nextRequestID
        nextRequestID += 1
        try await sendMessage(.object([
            "id": .number(Double(requestID)),
            "method": .string("turn/interrupt"),
            "params": .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
            ]),
        ]))
    }

    @discardableResult
    private func bindChatTurn(_ localTurnID: UUID, to turnID: String) async -> Bool {
        guard var runtime = chatTurnRuntimes[localTurnID] else { return false }
        if let existing = runtime.turnID {
            return existing == turnID
        }
        runtime.turnID = turnID
        chatTurnRuntimes[localTurnID] = runtime
        _ = await yieldChatTurnEvent(.started(turnID: turnID), to: localTurnID)
        return true
    }

    private func yieldChatTurnEvent(
        _ event: CodexAppServerChatTurnEvent,
        to localTurnID: UUID
    ) async -> Bool {
        guard let runtime = chatTurnRuntimes[localTurnID] else { return false }
        switch runtime.continuation.yield(event) {
        case .enqueued:
            return true
        case .terminated:
            await initiateChatTurnStopFromReader(localTurnID)
        case .dropped:
            await stopConnection(error: CodexAppServerError.backendResetForSafety)
        @unknown default:
            await stopConnection(error: CodexAppServerError.backendResetForSafety)
        }
        return false
    }

    /// Registers a chat-thread approval request and delivers it to the turn subscriber.
    /// Returns `false` for summary threads and unknown threads so the caller keeps the
    /// fail-closed decline.
    private func registerChatApprovalRequest(
        id: JSONValue,
        params: [String: JSONValue]?,
        message: JSONValue,
        responseKind: ApprovalResponseKind
    ) async -> Bool {
        guard let params,
              let threadID = params["threadId"]?.stringValue,
              chatThreadIDs.contains(threadID),
              let turnID = params["turnId"]?.stringValue,
              let approvalID = Self.approvalID(for: id)
        else { return false }
        let key = TurnKey(threadID: threadID, turnID: turnID)
        let pendingStartID = pendingStartID(for: key)
        pendingApprovals[approvalID] = PendingApproval(
            requestID: id,
            responseKind: responseKind,
            key: key,
            pendingStartID: pendingStartID
        )
        guard turnSubscribers[key]?.isEmpty == false || pendingStartID != nil else {
            await respondToApproval(id: approvalID, decision: .cancel)
            return true
        }
        await routeTurnMessage(message)
        return true
    }

    private func resolvePendingApprovals(
        for key: TurnKey,
        decision: CodexChatApprovalDecision
    ) async {
        let expired = pendingApprovals.filter { $0.value.key == key }
        for approvalID in expired.keys {
            await respondToApproval(id: approvalID, decision: decision)
        }
    }

    private func cleanUpFailedChatTurnStart(_ startID: UUID) async {
        let approvalIDs = pendingApprovals.compactMap { approvalID, approval in
            approval.pendingStartID == startID ? approvalID : nil
        }
        for approvalID in approvalIDs {
            await respondToApproval(id: approvalID, decision: .cancel)
        }
        let bufferedKeys = pendingChatTurnStarts[startID]?.bufferedKeys ?? []
        for key in bufferedKeys {
            rememberRetiredChatTurn(key)
            await interruptDiscoveredChatTurn(key)
            bufferedTurnMessages.removeValue(forKey: key)
        }
    }

    private func interruptDiscoveredChatTurn(_ key: TurnKey) async {
        guard !isShuttingDown,
              isInitialized,
              transport != nil,
              discoveredChatTurnStops[key] == nil,
              bufferedTurnMessages[key]?.contains(where: Self.isTurnCompletionMessage) != true
        else { return }

        let generation = connectionGeneration
        let timeoutTask = Task { [weak self, clock] in
            do {
                try await clock.sleep(for: Self.turnRecoveryTimeout)
                guard let self else { return }
                await self.resetConnectionForDiscoveredChatTurnTimeout(key, generation: generation)
            } catch {
                // Terminal completion cancels the owned timeout.
            }
        }
        discoveredChatTurnStops[key] = DiscoveredChatTurnStop(
            generation: generation,
            timeoutTask: timeoutTask
        )

        // Failed-start cleanup can run in an already-cancelled task. A fresh task ensures
        // the interrupt write is attempted after stop tracking has been installed.
        let interrupt = Task {
            try await self.sendTurnInterrupt(threadID: key.threadID, turnID: key.turnID)
        }
        do {
            try await interrupt.value
        } catch {
            guard let stop = discoveredChatTurnStops.removeValue(forKey: key),
                  stop.generation == generation
            else { return }
            stop.timeoutTask.cancel()
            resumeChatTurnDrainWaitersIfIdle()
            if generation == connectionGeneration {
                await stopConnection(error: CodexAppServerError.backendResetForSafety)
            }
        }
    }

    private func interruptLateChatTurnStartResponse(
        _ object: [String: JSONValue],
        threadID: String
    ) async {
        guard let turnID = object["result"]?.objectValue?["turn"]?.objectValue?["id"]?.stringValue else { return }
        let key = TurnKey(threadID: threadID, turnID: turnID)
        let shouldInterrupt = rememberRetiredChatTurn(key)
        await resolvePendingApprovals(for: key, decision: .cancel)
        if shouldInterrupt {
            await interruptDiscoveredChatTurn(key)
        }
        bufferedTurnMessages.removeValue(forKey: key)
    }

    private func reconcilePendingChatTurnStart(_ startID: UUID, with key: TurnKey) async {
        guard var pendingStart = pendingChatTurnStarts[startID] else { return }
        pendingStart.turnID = key.turnID
        let mismatchedKeys = pendingStart.bufferedKeys.filter { $0 != key }
        pendingStart.bufferedKeys.subtract(mismatchedKeys)
        pendingChatTurnStarts[startID] = pendingStart

        for mismatchedKey in mismatchedKeys {
            rememberRetiredChatTurn(mismatchedKey)
            await interruptDiscoveredChatTurn(mismatchedKey)
            bufferedTurnMessages.removeValue(forKey: mismatchedKey)
        }
        let approvalIDs = pendingApprovals.compactMap { approvalID, approval in
            approval.pendingStartID == startID && approval.key != key ? approvalID : nil
        }
        for approvalID in approvalIDs {
            await respondToApproval(id: approvalID, decision: .cancel)
        }
    }

    private func pendingStartID(for key: TurnKey) -> UUID? {
        pendingChatTurnStarts.first { _, pendingStart in
            pendingStart.threadID == key.threadID
                && (pendingStart.turnID == nil || pendingStart.turnID == key.turnID)
        }?.key
    }

    private func hasUnownedChatTurnStartRequest(for threadID: String) -> Bool {
        pendingRequests.values.contains { $0.lateChatTurnStartThreadID == threadID }
    }

    private func routeTurnMessage(_ message: JSONValue) async {
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
        if method == "turn/completed" {
            finishDiscoveredChatTurnStop(key)
        }
        let hasSubscribers = turnSubscribers[key]?.isEmpty == false
        turnSubscribers[key]?.values.forEach { $0.yield(message) }
        if turnWaiters[key] != nil {
            processTurnMessage(message, for: key)
        } else if !hasSubscribers {
            await routeUnsubscribedTurnMessage(message, method: method, key: key)
        }
        if method == "turn/completed" {
            await finishTurnSubscribers(for: key)
            if activeChatTurnIDs[threadID] == turnID {
                activeChatTurnIDs.removeValue(forKey: threadID)
            }
        }
    }

    private func routeUnsubscribedTurnMessage(
        _ message: JSONValue,
        method: String,
        key: TurnKey
    ) async {
        if let startID = pendingStartID(for: key) {
            bufferTurnMessage(message, for: key)
            pendingChatTurnStarts[startID]?.bufferedKeys.insert(key)
        } else if hasUnownedChatTurnStartRequest(for: key.threadID) {
            let shouldInterrupt = rememberRetiredChatTurn(key)
            if method != "turn/completed", shouldInterrupt {
                await interruptDiscoveredChatTurn(key)
            }
        } else if !chatThreadIDs.contains(key.threadID) {
            // Summary turns can emit notifications before their waiter is installed.
            bufferTurnMessage(message, for: key)
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
            request.continuation?.resume(throwing: error)
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
        activeChatTurnIDs.removeAll()
        subscribers.forEach { $0.finish(throwing: error) }
        // The transport is gone, so outstanding approvals cannot be answered.
        pendingApprovals.removeAll()
        chatThreadIDs.removeAll()
        let localTurnIDs = Array(chatTurnRuntimes.keys)
        for localTurnID in localTurnIDs {
            finishChatTurn(localTurnID, throwing: error)
        }
        let discoveredStops = discoveredChatTurnStops.values
        discoveredChatTurnStops.removeAll()
        discoveredStops.forEach { $0.timeoutTask.cancel() }
        retiredChatTurnKeys.removeAll()
        retiredChatTurnOrder.removeAll()
        resumeChatTurnDrainWaiters(throwing: error)
        await currentTransport?.close()
    }

    private func failRequest(_ requestID: Int, error: any Error) {
        pendingRequests.removeValue(forKey: requestID)?.continuation?.resume(throwing: error)
    }

    private func cancelRequest(_ requestID: Int) {
        guard var request = pendingRequests[requestID],
              let continuation = request.continuation else { return }
        if request.lateChatTurnStartThreadID != nil {
            request.continuation = nil
            pendingRequests[requestID] = request
        } else {
            pendingRequests.removeValue(forKey: requestID)
        }
        continuation.resume(throwing: CancellationError())
    }

    private func cancelTurnWaiter(_ key: TurnKey) {
        guard let waiter = turnWaiters.removeValue(forKey: key) else { return }
        waiter.timeoutTask.cancel()
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func chatTurnStartTimedOut(_ localTurnID: UUID, generation: Int) async {
        guard let runtime = chatTurnRuntimes[localTurnID],
              runtime.generation == generation,
              generation == connectionGeneration else { return }
        if runtime.turnID == nil {
            await stopConnection(error: CodexAppServerError.backendResetForSafety)
        } else {
            await stopChatTurn(localTurnID)
        }
    }

    private func armChatTurnStopTimeout(_ localTurnID: UUID, generation: Int) {
        chatTurnRuntimes[localTurnID]?.timeoutTask?.cancel()
        chatTurnRuntimes[localTurnID]?.timeoutTask = Task { [weak self, clock] in
            do {
                try await clock.sleep(for: Self.turnRecoveryTimeout)
                guard let self else { return }
                await self.resetConnectionForChatTurnTimeout(localTurnID, generation: generation)
            } catch {
                // Terminal completion cancels the owned timeout.
            }
        }
    }

    private func resetConnectionForChatTurnTimeout(_ localTurnID: UUID, generation: Int) async {
        guard chatTurnRuntimes[localTurnID]?.generation == generation,
              generation == connectionGeneration else { return }
        await stopConnection(error: CodexAppServerError.backendResetForSafety)
    }

    private func resetConnectionForDiscoveredChatTurnTimeout(_ key: TurnKey, generation: Int) async {
        guard discoveredChatTurnStops[key]?.generation == generation,
              generation == connectionGeneration else { return }
        await stopConnection(error: CodexAppServerError.backendResetForSafety)
    }

    private func finishDiscoveredChatTurnStop(_ key: TurnKey) {
        discoveredChatTurnStops.removeValue(forKey: key)?.timeoutTask.cancel()
        resumeChatTurnDrainWaitersIfIdle()
    }

    private func waitForChatTurnToFinish(_ localTurnID: UUID) async {
        guard chatTurnRuntimes[localTurnID] != nil else { return }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard chatTurnRuntimes[localTurnID] != nil else {
                    continuation.resume()
                    return
                }
                chatTurnRuntimes[localTurnID]?.stopWaiters[waiterID] = continuation
            }
        } onCancel: {
            Task { await self.removeChatTurnStopWaiter(waiterID, localTurnID: localTurnID) }
        }
    }

    private func removeChatTurnStopWaiter(_ waiterID: UUID, localTurnID: UUID) {
        chatTurnRuntimes[localTurnID]?.stopWaiters.removeValue(forKey: waiterID)?.resume()
    }

    private func finishChatTurn(_ localTurnID: UUID, throwing error: (any Error)? = nil) {
        guard let runtime = chatTurnRuntimes.removeValue(forKey: localTurnID) else { return }
        if let turnID = runtime.turnID {
            rememberRetiredChatTurn(TurnKey(threadID: runtime.threadID, turnID: turnID))
        }
        runtime.timeoutTask?.cancel()
        if let error {
            runtime.continuation.finish(throwing: error)
        } else {
            runtime.continuation.finish()
        }
        runtime.stopWaiters.values.forEach { $0.resume() }
        resumeChatTurnDrainWaitersIfIdle()
    }

    @discardableResult
    private func rememberRetiredChatTurn(_ key: TurnKey) -> Bool {
        guard retiredChatTurnKeys.insert(key).inserted else { return false }
        retiredChatTurnOrder.append(key)
        while retiredChatTurnOrder.count > 64 {
            retiredChatTurnKeys.remove(retiredChatTurnOrder.removeFirst())
        }
        return true
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

    private func removeTurnSubscriber(_ subscriberID: UUID, for key: TurnKey) async {
        turnSubscribers[key]?.removeValue(forKey: subscriberID)
        if turnSubscribers[key]?.isEmpty == true {
            turnSubscribers.removeValue(forKey: key)
            await resolvePendingApprovals(for: key, decision: .cancel)
        }
        resumeChatTurnDrainWaitersIfIdle()
    }

    private func finishTurnSubscribers(for key: TurnKey) async {
        await resolvePendingApprovals(for: key, decision: .decline)
        guard let subscribers = turnSubscribers.removeValue(forKey: key)?.values else { return }
        subscribers.forEach { $0.finish() }
        resumeChatTurnDrainWaitersIfIdle()
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

    private func beginCodexOperation() async throws -> UUID {
        try await waitForConfigurationReloadToFinish()
        let operationID = UUID()
        activeCodexOperations.insert(operationID)
        return operationID
    }

    private func beginCodexOperation(bypassingAdmission: Bool) async throws -> UUID? {
        guard !bypassingAdmission else { return nil }
        return try await beginCodexOperation()
    }

    private func finishCodexOperation(_ operationID: UUID) {
        activeCodexOperations.remove(operationID)
        guard activeCodexOperations.isEmpty else { return }
        resumeCodexOperationDrainWaiters()
    }

    private func finishCodexOperation(_ operationID: UUID?) {
        guard let operationID else { return }
        finishCodexOperation(operationID)
    }

    private func waitForCodexOperationsToFinish() async throws {
        guard !activeCodexOperations.isEmpty else { return }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if activeCodexOperations.isEmpty {
                    continuation.resume()
                } else {
                    codexOperationDrainWaiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelCodexOperationDrainWaiter(waiterID) }
        }
    }

    private func cancelCodexOperationDrainWaiter(_ waiterID: UUID) {
        codexOperationDrainWaiters.removeValue(forKey: waiterID)?.resume(throwing: CancellationError())
    }

    private func resumeCodexOperationDrainWaiters(throwing error: (any Error)? = nil) {
        let waiters = codexOperationDrainWaiters.values
        codexOperationDrainWaiters.removeAll()
        for waiter in waiters {
            if let error {
                waiter.resume(throwing: error)
            } else {
                waiter.resume()
            }
        }
    }

    private func waitForChatTurnsToFinish() async throws {
        guard !pendingChatTurnStarts.isEmpty
            || !turnSubscribers.isEmpty
            || !chatTurnRuntimes.isEmpty
            || !discoveredChatTurnStops.isEmpty
        else { return }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if pendingChatTurnStarts.isEmpty,
                          turnSubscribers.isEmpty,
                          chatTurnRuntimes.isEmpty,
                          discoveredChatTurnStops.isEmpty {
                    continuation.resume()
                } else {
                    chatTurnDrainWaiters[waiterID] = continuation
                    #if DEBUG
                        let testWaiters = chatTurnDrainTestWaiters
                        chatTurnDrainTestWaiters.removeAll()
                        testWaiters.forEach { $0.resume() }
                    #endif
                }
            }
        } onCancel: {
            Task { await self.cancelChatTurnDrainWaiter(waiterID) }
        }
    }

    private func cancelChatTurnDrainWaiter(_ waiterID: UUID) {
        chatTurnDrainWaiters.removeValue(forKey: waiterID)?.resume(throwing: CancellationError())
    }

    private func resumeChatTurnDrainWaitersIfIdle() {
        guard pendingChatTurnStarts.isEmpty,
              turnSubscribers.isEmpty,
              chatTurnRuntimes.isEmpty,
              discoveredChatTurnStops.isEmpty
        else { return }
        resumeChatTurnDrainWaiters()
    }

    private func resumeChatTurnDrainWaiters(throwing error: (any Error)? = nil) {
        let waiters = chatTurnDrainWaiters.values
        chatTurnDrainWaiters.removeAll()
        for waiter in waiters {
            if let error {
                waiter.resume(throwing: error)
            } else {
                waiter.resume()
            }
        }
    }

    private func waitForConfigurationReloadToFinish() async throws {
        guard isConfigurationReloading else { return }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if isConfigurationReloading {
                    configurationReloadWaiters[waiterID] = continuation
                } else {
                    continuation.resume()
                }
            }
        } onCancel: {
            Task { await self.cancelConfigurationReloadWaiter(waiterID) }
        }
    }

    private func cancelConfigurationReloadWaiter(_ waiterID: UUID) {
        configurationReloadWaiters.removeValue(forKey: waiterID)?.resume(throwing: CancellationError())
    }

    private func finishConfigurationReload(throwing error: (any Error)? = nil) {
        isConfigurationReloading = false
        resumeConfigurationReloadWaiters(throwing: error)
    }

    private func resumeConfigurationReloadWaiters(throwing error: (any Error)? = nil) {
        let waiters = configurationReloadWaiters.values
        configurationReloadWaiters.removeAll()
        for waiter in waiters {
            if let error {
                waiter.resume(throwing: error)
            } else {
                waiter.resume()
            }
        }
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

        func waitUntilChatTurnReloadIsWaitingForTesting() async {
            if !chatTurnDrainWaiters.isEmpty { return }
            await withCheckedContinuation { continuation in
                chatTurnDrainTestWaiters.append(continuation)
            }
        }

        var codexOperationDrainWaiterCountForTesting: Int {
            codexOperationDrainWaiters.count
        }

        func hasPendingApprovalForTesting(_ approvalID: String) -> Bool {
            pendingApprovals[approvalID] != nil
        }

        func hasOwnedChatApprovalForTesting(turnID: UUID, approvalID: String) -> Bool {
            chatTurnRuntimes[turnID]?.pendingApprovals[approvalID] != nil
        }

        func hasRespondedChatApprovalForTesting(turnID: UUID, approvalID: String) -> Bool {
            chatTurnRuntimes[turnID]?.respondedApprovalIDs.contains(approvalID) == true
        }

        func hasBufferedTurnMessagesForTesting(threadID: String, turnID: String) -> Bool {
            bufferedTurnMessages[TurnKey(threadID: threadID, turnID: turnID)]?.isEmpty == false
        }

        func hasTurnSubscriberForTesting(threadID: String, turnID: String) -> Bool {
            turnSubscribers[TurnKey(threadID: threadID, turnID: turnID)]?.isEmpty == false
        }

        func hasDiscoveredChatTurnStopForTesting(threadID: String, turnID: String) -> Bool {
            discoveredChatTurnStops[TurnKey(threadID: threadID, turnID: turnID)] != nil
        }

        var providerAuthenticationWaiterCountForTesting: Int {
            providerAuthenticationPreparationState?.waiters.count ?? 0
        }
    }
#endif
