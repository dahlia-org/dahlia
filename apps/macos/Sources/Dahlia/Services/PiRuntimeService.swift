import DahliaRuntimeSupport
import Foundation

/// Starts the installed Pi for the selected account. Each summary, model listing, and sign-in uses its
/// own short-lived process; chat keeps one process per open thread (see `PiChatService`).
actor PiRuntimeService {
    nonisolated static let summaryTimeout = Duration.seconds(610)
    nonisolated static let controlTimeout = Duration.seconds(30)
    nonisolated static let loginTimeout = Duration.seconds(600)

    static let shared = PiRuntimeService()

    /// Posted when listed models may have changed (sign-in, sign-out, account switch); model pickers reload.
    nonisolated static let modelsDidChange = Notification.Name("DahliaPiModelsDidChange")

    struct LaunchOptions: Sendable {
        enum Mode: String, Sendable {
            case control
            case summary
            case chat
        }

        var mode: Mode
        var cwd: URL
        var arguments: [String] = []
        var environment: [String: String] = [:]
    }

    struct AccountStatus: Equatable {
        let isAuthenticated: Bool
    }

    /// Answers the chat extension's `approval` and `approvalMode` requests.
    typealias ChatBridge = PiRPCConnection.Bridge
    typealias Launcher = @Sendable (LaunchOptions, CodexRuntimeProvider, URL) throws -> any CodexAppServerTransport
    typealias TokenResolver = @Sendable (CodexRuntimeProvider) async throws -> String

    private let agentLocator: PiAgentDirectoryLocator
    private let contextStore: CodexRuntimeContextStore
    private let configurationReadiness: @Sendable () async -> Bool
    private let launcher: Launcher
    private let tokenResolver: TokenResolver
    private var connections: [ObjectIdentifier: (connection: PiRPCConnection, provider: CodexRuntimeProvider)] = [:]
    private var cachedModels: [CodexRuntimeProvider: [CodexModel]] = [:]
    private var modelLoads: [CodexRuntimeProvider: (task: Task<[CodexModel], any Error>, waiters: Int)] = [:]
    private var modelGeneration = 0
    private var isShuttingDown = false

    init(
        agentLocator: PiAgentDirectoryLocator = PiAgentDirectoryLocator(),
        contextStore: CodexRuntimeContextStore = .shared,
        configurationReadiness: @escaping @Sendable () async -> Bool = {
            await WorkspaceAISettingsModel.shared.waitForRuntimeContext()
        },
        launcher: @escaping Launcher = PiRuntimeService.launchPi,
        tokenResolver: @escaping TokenResolver = PiRuntimeService.resolveToken
    ) {
        self.agentLocator = agentLocator
        self.contextStore = contextStore
        self.configurationReadiness = configurationReadiness
        self.launcher = launcher
        self.tokenResolver = tokenResolver
    }

    // MARK: Lifecycle

    /// Starts a Pi process. The caller owns it and must call `close(_:)`.
    func connect(
        _ options: LaunchOptions,
        provider: CodexRuntimeProvider,
        chatBridge: ChatBridge? = nil
    ) async throws -> PiRPCConnection {
        guard !isShuttingDown else { throw CancellationError() }
        // Work of an account being left must not start Pi after the switch drained its processes. The Local
        // Account's control processes (subscription sign-in and status) run whichever account is open.
        if let requested = contextStore.requestedProvider, requested != provider, options.mode != .control || provider != .local {
            throw CodexConfigurationError.providerChanged(provider.displayName)
        }
        let agentURL = try agentLocator.agentURL(for: provider)
        let transport = try launcher(options, provider, agentURL)
        let tokenResolver = tokenResolver
        let connection = PiRPCConnection(transport: transport) { method, payload in
            switch method {
            case "token":
                do {
                    return try await .string(tokenResolver(provider))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Callers defer work and skip error reporting for this case, as they did for Codex's auth command.
                    throw CodexAppServerError.providerAuthenticationFailed(error.localizedDescription)
                }
            case "approval", "approvalMode":
                guard let chatBridge else { return .string(method == "approval" ? "decline" : "ask") }
                return try await chatBridge(method, payload)
            default:
                throw CodexAppServerError.invalidProtocolResponse
            }
        }
        connections[ObjectIdentifier(connection)] = (connection, provider)
        await connection.start()
        return connection
    }

    func close(_ connection: PiRPCConnection) async {
        connections.removeValue(forKey: ObjectIdentifier(connection))
        await connection.close()
    }

    /// Applies an account change. Interrupting closes every running Pi process, including chat.
    func reloadConfiguration(
        applyingContext: (@Sendable () async throws -> Void)? = nil,
        interruptActiveOperations: Bool = false
    ) async throws {
        guard !isShuttingDown else { throw CancellationError() }
        if interruptActiveOperations { await closeAll() }
        try await applyingContext?()
        invalidateModels()
    }

    func shutdown() async {
        isShuttingDown = true
        await closeAll()
    }

    /// Closes every running process, or only one account's, such as after its credentials changed.
    private func closeAll(of provider: CodexRuntimeProvider? = nil) async {
        let closing = connections.filter { provider == nil || $0.value.provider == provider }
        for (key, entry) in closing {
            connections.removeValue(forKey: key)
            await entry.connection.close()
        }
    }

    func currentProvider(expected: CodexRuntimeProvider? = nil) async throws -> CodexRuntimeProvider {
        guard await configurationReadiness() else { throw CodexConfigurationError.accountNotReady }
        let provider = contextStore.provider
        if let expected, expected != provider { throw CodexConfigurationError.accountNotReady }
        return provider
    }

    // MARK: Models

    func models(forceRefresh: Bool = false) async throws -> [CodexModel] {
        try await models(for: currentProvider(), forceRefresh: forceRefresh)
    }

    private func models(for provider: CodexRuntimeProvider, forceRefresh: Bool) async throws -> [CodexModel] {
        let models = try await listedModels(provider, forceRefresh: forceRefresh)
        if models.isEmpty, provider.accountConnectionID == nil { throw CodexAppServerError.notLoggedIn }
        guard contextStore.provider == provider else { throw CodexConfigurationError.providerChanged(provider.displayName) }
        return models
    }

    /// One Pi listing per account at a time, joined by every caller and cancelled when every caller is. A listing
    /// that started before an invalidation is not cached, and an empty list (nothing signed in, Server unreachable)
    /// is listed again next time.
    private func listedModels(_ provider: CodexRuntimeProvider, forceRefresh: Bool) async throws -> [CodexModel] {
        if !forceRefresh, let cached = cachedModels[provider] { return cached }
        let generation = modelGeneration
        let load = modelLoads[provider]?.task ?? Task {
            if case .dahlia = provider { await self.refreshDahliaCatalog(provider) }
            return try await self.availableModels(provider: provider)
        }
        modelLoads[provider] = (load, (modelLoads[provider]?.waiters ?? 0) + 1)
        let result = await withTaskCancellationHandler {
            await Result { try await load.value }
        } onCancel: {
            Task { await self.leaveModelLoad(load, provider: provider) }
        }
        if modelLoads[provider]?.task == load { modelLoads[provider] = nil }
        let models = try result.get()
        if generation == modelGeneration, !models.isEmpty { cachedModels[provider] = models }
        return models
    }

    private func leaveModelLoad(_ load: Task<[CodexModel], any Error>, provider: CodexRuntimeProvider) {
        guard modelLoads[provider]?.task == load else { return }
        modelLoads[provider]?.waiters -= 1
        if modelLoads[provider]?.waiters == 0 {
            modelLoads[provider] = nil
            load.cancel()
        }
    }

    private func invalidateModels() {
        cachedModels.removeAll()
        modelLoads.removeAll()
        modelGeneration += 1
        NotificationCenter.default.post(name: Self.modelsDidChange, object: nil)
    }

    /// Fetches the Dahlia Server's model list into `models.json`. Failure keeps the last list.
    private func refreshDahliaCatalog(_ provider: CodexRuntimeProvider) async {
        guard let agentURL = try? agentLocator.agentURL(for: provider),
              let baseURL = PiProviderConfiguration.dahliaBaseURL(agentURL: agentURL),
              let token = try? await tokenResolver(provider),
              let catalog = try? await PiProviderConfiguration.fetchDahliaCatalog(baseURL: baseURL, token: token),
              let providers = try? PiProviderConfiguration.dahliaProvider(baseURL: baseURL, catalog: catalog)
        else { return }
        try? PiProviderConfiguration.write(providers, agentURL: agentURL)
    }

    private func availableModels(provider: CodexRuntimeProvider) async throws -> [CodexModel] {
        let cwd = try agentLocator.agentURL(for: provider)
        let connection = try await connect(.init(mode: .control, cwd: cwd, arguments: ["--no-session", "--no-tools"]), provider: provider)
        let result = await Result { try await connection.request("get_available_models", timeout: Self.controlTimeout) }
        await close(connection)
        let providerIDs = Set(provider.piProviderIDs)
        return try (result.get().objectValue?["models"]?.arrayValue ?? [])
            .compactMap(\.objectValue)
            .filter { $0["provider"]?.stringValue.map(providerIDs.contains) == true }
            .compactMap(PiProviderConfiguration.codexModel)
    }

    // MARK: Subscription sign-in (Local Account only)

    /// Signed in when Pi lists a model of that subscription; shares the cached or in-flight listing.
    func accountStatus(for subscription: PiSubscription) async throws -> AccountStatus {
        let models = try await listedModels(.local, forceRefresh: false)
        return AccountStatus(isAuthenticated: models.contains { $0.model.hasPrefix("\(subscription.rawValue)/") })
    }

    /// Runs Pi's own OAuth flow. Cancelling the task closes Pi and its localhost callback server.
    func signIn(_ subscription: PiSubscription, openURL: @escaping @Sendable (URL) async -> Bool) async throws {
        let providerID = subscription.rawValue
        let provider = CodexRuntimeProvider.local
        let cwd = try agentLocator.agentURL(for: .local)
        let connection = try await connect(.init(
            mode: .control,
            cwd: cwd,
            arguments: ["--no-session", "--no-tools"],
            environment: ["DAHLIA_PI_DEVICE_ID": agentLocator.deviceID()]
        ), provider: provider)
        let result = await Result {
            try await PiRPCConnection.withTimeout(Self.loginTimeout) {
                let command = Task { try? await connection.request("prompt", ["message": .string("/dahlia-login \(providerID)")]) }
                defer { command.cancel() }
                for try await event in connection.events {
                    guard let message = Self.notification(event) else { continue }
                    if message.hasPrefix("dahlia:auth_url ") {
                        guard let url = URL(string: String(message.dropFirst("dahlia:auth_url ".count))),
                              url.scheme?.lowercased() == "https", url.host != nil
                        else { throw CodexAppServerError.invalidProtocolResponse }
                        guard await openURL(url) else { throw CodexAppServerError.loginPageCouldNotOpen }
                    } else if message == "dahlia:login_succeeded" {
                        return
                    } else if message.hasPrefix("dahlia:login_failed") {
                        throw CodexAppServerError.loginFailed(String(message.dropFirst("dahlia:login_failed".count)).nilIfBlank)
                    }
                }
                throw CancellationError()
            }
        }
        await close(connection)
        try result.get()
        await credentialsDidChange()
    }

    func signOut(_ subscription: PiSubscription) async throws {
        let providerID = subscription.rawValue
        let provider = CodexRuntimeProvider.local
        let cwd = try agentLocator.agentURL(for: .local)
        let connection = try await connect(.init(mode: .control, cwd: cwd, arguments: ["--no-session", "--no-tools"]), provider: provider)
        let result = await Result {
            try await connection.request("prompt", ["message": .string("/dahlia-logout \(providerID)")], timeout: Self.controlTimeout)
        }
        await close(connection)
        _ = try result.get()
        await credentialsDidChange()
    }

    /// Running chats reopen with the new credentials on their next turn, and model pickers reload.
    private func credentialsDidChange() async {
        await closeAll(of: .local)
        invalidateModels()
    }

    nonisolated static func notification(_ event: JSONValue) -> String? {
        guard let object = event.objectValue,
              object["type"]?.stringValue == "extension_ui_request",
              object["method"]?.stringValue == "notify" else { return nil }
        return object["message"]?.stringValue
    }

    // MARK: Structured generation

    /// Returns one JSON object that matches `request.outputSchema`. Refusals, Markdown, truncated, and empty
    /// replies fail instead of reaching a Markdown fallback.
    func generate(
        _ request: CodexAppServerRequest,
        expectedProvider: CodexRuntimeProvider? = nil
    ) async throws -> String {
        let provider = try await currentProvider(expected: expectedProvider)
        let model: CodexModel
        do {
            model = try await Self.resolvedModel(for: request, in: models(for: provider, forceRefresh: false))
        } catch CodexAppServerError.requestedModelUnavailable {
            // The account may have gained the model since the catalog was cached.
            model = try await Self.resolvedModel(for: request, in: models(for: provider, forceRefresh: true))
        }
        let inputs = model.supportsImages ? request.inputs : request.inputs.filter { !$0.isImageRelated }
        let workURL = FileManager.default.temporaryDirectory.appending(path: "dahlia-pi-\(UUID().uuidString)", directoryHint: .isDirectory)
        try PiAgentDirectoryLocator.createPrivateDirectory(workURL)
        defer { try? FileManager.default.removeItem(at: workURL) }
        let schemaURL = workURL.appending(path: "output-schema.json")
        try request.outputSchema.write(to: schemaURL)

        let instructions = request.developerInstructions + """


        # Output
        Do not call tools. Reply with only one JSON object, without Markdown fences, that matches this JSON Schema:
        \(String(decoding: request.outputSchema, as: UTF8.self))
        """
        let arguments = [
            "--no-session", "--no-tools", "--system-prompt", instructions,
            "--model", model.model, "--thinking", Self.thinkingLevel(request.reasoningEffort),
        ]
        var environment = ["PI_OUTPUT_JSON_SCHEMA": schemaURL.path]
        if Self.supportsStrictSchema(model: model.model) { environment["PI_OUTPUT_STRICT_SCHEMA"] = "1" }

        let connection = try await connect(
            .init(mode: .summary, cwd: workURL, arguments: arguments, environment: environment),
            provider: provider
        )
        let prompt = Self.prompt(inputs)
        let result = await Result {
            try await PiRPCConnection.withTimeout(Self.summaryTimeout) {
                _ = try await connection.request("prompt", prompt)
                return try await Self.finalAssistantText(connection.events)
            }
        }
        // A failed sign-in or token refresh explains the failure better than the provider error it caused.
        let bridgeError = await connection.takeBridgeError()
        await close(connection)
        if case .failure = result, let bridgeError { throw bridgeError }
        try Task.checkCancellation()
        return try Self.jsonObjectText(result.get())
    }

    /// Matches a `provider/id` reference exactly, or a Codex-era bare model name by its ID suffix
    /// (`gpt-6-luna` → `openai/gpt-6-luna` or `…/system.ai.gpt-6-luna`). An exact-model request whose model is
    /// missing fails as unavailable; any other request falls back to the first suitable model.
    nonisolated static func resolvedModel(for request: CodexAppServerRequest, in models: [CodexModel]) throws -> CodexModel {
        let suitable = request.requiresImageInput ? models.filter(\.supportsImages) : models
        if let requested = request.model?.nilIfBlank {
            if let match = matchingModel(requested, in: suitable) { return match }
            if request.requiresExactModel { throw CodexAppServerError.requestedModelUnavailable(requested) }
        }
        guard let fallback = suitable.first else {
            throw CodexAppServerError.requestedModelUnavailable(request.model ?? "")
        }
        return fallback
    }

    /// The model a saved value names: the exact `provider/id`, or for a Codex-era bare name the model whose ID ends with it.
    nonisolated static func matchingModel(_ saved: String, in models: [CodexModel]) -> CodexModel? {
        let saved = saved.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !saved.isEmpty else { return nil }
        if let exact = models.first(where: { $0.model == saved }) { return exact }
        guard !saved.contains("/") else { return nil }
        return models.first { $0.model.hasSuffix("/\(saved)") || $0.model.hasSuffix(".\(saved)") }
    }

    /// Models whose API the extension can make enforce the schema (OpenAI Responses, Claude Messages, Gemini).
    nonisolated static func supportsStrictSchema(model: String) -> Bool {
        // Databricks also serves other models (GLM, Kimi) as OpenAI Responses on its MLflow route, which takes no strict schema.
        ["openai/", "anthropic/", "dahlia/", "databricks/system.ai.gpt-", "databricks/system.ai.claude-", "databricks/system.ai.gemini-"]
            .contains { model.hasPrefix($0) }
    }

    nonisolated static func thinkingLevel(_ effort: String) -> String {
        effort == "none" ? "off" : effort.nilIfBlank ?? CodexReasoningEffortOption.defaultValue
    }

    /// Pi takes one text message with images attached in order, so image metadata is numbered in the text.
    nonisolated static func prompt(_ inputs: [CodexAppServerInput]) -> [String: JSONValue] {
        var texts: [String] = []
        var images: [JSONValue] = []
        for input in inputs {
            switch input {
            case let .text(text):
                texts.append(text)
            case let .imageMetadata(text):
                texts.append("[Attached image \(images.count + 1)] \(text)")
            case let .imageDataURI(uri):
                guard let image = piImage(dataURI: uri) else { continue }
                images.append(image)
            }
        }
        var prompt: [String: JSONValue] = ["message": .string(texts.joined(separator: "\n\n"))]
        if !images.isEmpty { prompt["images"] = .array(images) }
        return prompt
    }

    nonisolated static func piImage(dataURI: String) -> JSONValue? {
        guard dataURI.hasPrefix("data:"),
              let comma = dataURI.firstIndex(of: ","),
              case let header = dataURI[dataURI.index(dataURI.startIndex, offsetBy: 5) ..< comma],
              header.hasSuffix(";base64")
        else { return nil }
        return .object([
            "type": .string("image"),
            "data": .string(String(dataURI[dataURI.index(after: comma)...])),
            "mimeType": .string(String(header.dropLast(";base64".count))),
        ])
    }

    /// Waits for `agent_settled` and returns the last assistant message's text.
    nonisolated static func finalAssistantText(_ events: AsyncThrowingStream<JSONValue, any Error>) async throws -> String {
        var message: [String: JSONValue]?
        for try await event in events {
            guard let object = event.objectValue else { continue }
            switch object["type"]?.stringValue {
            case "message_end":
                if let candidate = object["message"]?.objectValue, candidate["role"]?.stringValue == "assistant" {
                    message = candidate
                }
            case "agent_settled":
                return try assistantText(message)
            default:
                continue
            }
        }
        throw CodexAppServerError.processExited(nil)
    }

    nonisolated static func assistantText(_ message: [String: JSONValue]?) throws -> String {
        guard let message else { throw CodexAppServerError.emptyResponse }
        switch message["stopReason"]?.stringValue {
        case "stop", "toolUse":
            break
        case "aborted":
            throw CancellationError()
        case "error":
            let detail = message["errorMessage"]?.stringValue
            if isAuthenticationFailure(detail) { throw CodexAppServerError.notLoggedIn }
            throw CodexAppServerError.turnFailed(detail)
        default:
            throw CodexAppServerError.turnFailed(message["stopReason"]?.stringValue)
        }
        let text = (message["content"]?.arrayValue ?? []).compactMap { block -> String? in
            guard block.objectValue?["type"]?.stringValue == "text" else { return nil }
            return block.objectValue?["text"]?.stringValue
        }.joined()
        guard text.nilIfBlank != nil else { throw CodexAppServerError.emptyResponse }
        return text
    }

    /// An HTTP 401 or Pi's missing-credential message; a bare "401" inside other numbers does not count.
    nonisolated static func isAuthenticationFailure(_ detail: String?) -> Bool {
        guard let detail = detail?.lowercased() else { return false }
        return detail.range(of: #"(^|[^0-9])401([^0-9]|$)"#, options: .regularExpression) != nil
            || detail.contains("unauthorized") || detail.contains("no api key") || detail.contains("not logged in")
    }

    /// Accepts a bare JSON object or one wrapped in a Markdown code fence.
    nonisolated static func jsonObjectText(_ text: String) throws -> String {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("```"), candidate.hasSuffix("```"), let firstNewline = candidate.firstIndex(of: "\n") {
            candidate = String(candidate[candidate.index(after: firstNewline) ..< candidate.index(candidate.endIndex, offsetBy: -3)])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard (try? JSONDecoder().decode(JSONValue.self, from: Data(candidate.utf8)))?.objectValue != nil else {
            throw CodexAppServerError.invalidProtocolResponse
        }
        return candidate
    }

    // MARK: Defaults

    nonisolated static func launchPi(
        _ options: LaunchOptions,
        provider: CodexRuntimeProvider,
        agentURL: URL
    ) throws -> any CodexAppServerTransport {
        // Provider keys in Dahlia's own environment must not override the account's sign-in or reach model-run commands.
        var environment = ProcessInfo.processInfo.environment.filter { key, _ in
            !key.hasSuffix("_API_KEY") && !key.hasSuffix("_AUTH_TOKEN") && !key.hasSuffix("_OAUTH_TOKEN") && !key.hasPrefix("PI_")
        }
        let executableURL = try PiBundle.executableURL(for: provider)
        environment["PATH"] = CommandLineToolLocator.searchPath(for: executableURL, environment: environment)
        environment["PI_CODING_AGENT_DIR"] = agentURL.path
        environment["PI_OFFLINE"] = "1"
        environment["PI_SKIP_VERSION_CHECK"] = "1"
        environment["PI_TELEMETRY"] = "0"
        environment["DAHLIA_PI_MODE"] = options.mode.rawValue
        environment["DAHLIA_PI_BRIDGED_PROVIDERS"] = provider.piBridgedProviderIDs.joined(separator: ",")
        environment.merge(options.environment) { $1 }
        let arguments = try [
            "--mode", "rpc",
            "--no-extensions", "-e", PiBundle.resourceURL("dahlia.ts").path,
            "--no-skills", "--no-context-files", "--no-prompt-templates", "--no-themes", "--no-approve",
        ] + options.arguments
        return try CodexAppServerProcessTransport(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            currentDirectoryURL: options.cwd
        )
    }

    nonisolated static func resolveToken(_ provider: CodexRuntimeProvider) async throws -> String {
        switch provider {
        case let .dahlia(connectionID):
            return try await DahliaCloudTokenServiceRegistry.shared.validAccessToken(connectionID: connectionID)
        case let .databricks(connectionID):
            return try await DatabricksOAuthService.shared.accessToken(connectionID: connectionID)
        case .local:
            // The subscriptions keep their own sign-ins; nothing is bridged.
            throw CodexConfigurationError.databricksProfileRequired
        }
    }
}

private extension Result where Failure == any Error {
    init(catching body: () async throws -> Success) async {
        do { self = try await .success(body()) } catch { self = .failure(error) }
    }
}
