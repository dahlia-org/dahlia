import DahliaRuntimeSupport
import Foundation
import os

/// Starts the installed Pi for the selected account. Each summary, model listing, and sign-in uses its
/// own short-lived process; chat keeps one process per open thread (see `PiChatService`).
actor PiRuntimeService {
    nonisolated static let summaryTimeout = Duration.seconds(610)
    nonisolated static let controlTimeout = Duration.seconds(30)
    nonisolated static let loginTimeout = Duration.seconds(600)

    static let shared = PiRuntimeService()

    /// Posted when listed models may have changed (sign-in, sign-out, account switch); model pickers reload.
    nonisolated static let modelsDidChange = Notification.Name("DahliaPiModelsDidChange")
    /// Counts those changes, so a chat that was hidden when one was posted lists again when it shows.
    nonisolated static let modelsGeneration = OSAllocatedUnfairLock(initialState: 0)

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
        var fileAccess = PiFileAccessSettings()
    }

    struct AccountStatus: Equatable {
        let isAuthenticated: Bool
    }

    /// Answers the chat extension's approval and reviewer-model requests.
    typealias ChatBridge = PiRPCConnection.Bridge
    typealias Launcher = @Sendable (LaunchOptions, CodexRuntimeProvider, URL) throws -> any CodexAppServerTransport
    typealias TokenResolver = @Sendable (CodexRuntimeProvider) async throws -> String

    private let agentLocator: PiAgentDirectoryLocator
    private let contextStore: CodexRuntimeContextStore
    private let configurationReadiness: @Sendable () async -> Bool
    private let launcher: Launcher
    private let tokenResolver: TokenResolver
    private let modelChoices: @Sendable (CodexRuntimeProvider) -> [String: Bool]
    private let gatewayWorkspaces: @Sendable (CodexRuntimeProvider) -> [AgentMCPProvider]
    private var connections: [ObjectIdentifier: (connection: PiRPCConnection, provider: CodexRuntimeProvider, mode: LaunchOptions.Mode)] = [:]
    private var cachedModels: [CodexRuntimeProvider: [CodexModel]] = [:]
    private var modelLoads: [CodexRuntimeProvider: (task: Task<[CodexModel], any Error>, waiters: Int)] = [:]
    private var modelGeneration = 0
    /// Each account's background listing of its Unity AI Gateways in this activation (see `refreshGateways`).
    private var gatewayRefreshes: [CodexRuntimeProvider: Task<Void, Never>] = [:]
    /// Each gateway's listing in flight, by account and provider ID. Every caller joins it, and only the listing still
    /// registered here saves its answer: an activation or sign-in drops the registration, so an older answer that lands
    /// after a newer listing started is discarded.
    private var gatewayListings: [CodexRuntimeProvider: [String: Task<[JSONValue], any Error>]] = [:]
    private var isShuttingDown = false

    init(
        agentLocator: PiAgentDirectoryLocator = PiAgentDirectoryLocator(),
        contextStore: CodexRuntimeContextStore = .shared,
        configurationReadiness: @escaping @Sendable () async -> Bool = {
            await WorkspaceAISettingsModel.shared.waitForRuntimeContext()
        },
        launcher: @escaping Launcher = PiRuntimeService.launchPi,
        tokenResolver: @escaping TokenResolver = PiRuntimeService.resolveToken,
        modelChoices: @escaping @Sendable (CodexRuntimeProvider) -> [String: Bool] = { AgentModelSettings.choices(for: $0) },
        gatewayWorkspaces: @escaping @Sendable (CodexRuntimeProvider) -> [AgentMCPProvider] = {
            AgentMCPSettings.load(for: $0).providers.filter { !$0.isAccount }
        }
    ) {
        self.agentLocator = agentLocator
        self.contextStore = contextStore
        self.configurationReadiness = configurationReadiness
        self.launcher = launcher
        self.tokenResolver = tokenResolver
        self.modelChoices = modelChoices
        self.gatewayWorkspaces = gatewayWorkspaces
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
            case "approval", "approvalMode", "reviewModel":
                guard let chatBridge else { return .string(method == "approval" ? "decline" : method == "reviewModel" ? "" : "ask") }
                return try await chatBridge(method, payload)
            default:
                throw CodexAppServerError.invalidProtocolResponse
            }
        }
        connections[ObjectIdentifier(connection)] = (connection, provider, options.mode)
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
        // An activated account lists its gateways again.
        gatewayRefreshes.removeAll()
        gatewayListings.removeAll()
        invalidateModels()
    }

    func shutdown() async {
        isShuttingDown = true
        await closeAll()
    }

    /// Closes every running process, or only one account's (of one mode), such as after its credentials changed.
    private func closeAll(of provider: CodexRuntimeProvider? = nil, mode: LaunchOptions.Mode? = nil) async {
        let closing = connections.filter { (provider == nil || $0.value.provider == provider) && (mode == nil || $0.value.mode == mode) }
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

    func models(for provider: CodexRuntimeProvider, forceRefresh: Bool) async throws -> [CodexModel] {
        let models = try await listedModels(provider, forceRefresh: forceRefresh)
        if models.isEmpty, provider.accountConnectionID == nil { throw CodexAppServerError.notLoggedIn }
        guard contextStore.provider == provider else { throw CodexConfigurationError.providerChanged(provider.displayName) }
        return models
    }

    /// One Pi listing per account at a time, joined by every caller and cancelled when every caller is. A listing
    /// that started before an invalidation (a sign-in, a model switch in Agents settings) is neither cached nor
    /// returned: its callers list again, so a slower old listing cannot replace a newer one. An empty list (nothing
    /// signed in, Server unreachable) is listed again next time.
    private func listedModels(_ provider: CodexRuntimeProvider, forceRefresh: Bool) async throws -> [CodexModel] {
        if !forceRefresh, let cached = cachedModels[provider] { return cached }
        let generation = modelGeneration
        let load = modelLoads[provider]?.task ?? Task {
            if case .dahlia = provider { await self.refreshDahliaCatalog(provider) }
            return try await self.availableModels(provider: provider)
        }
        // Only the open account lists its gateways; the Local Account's subscription status lists it while another is open.
        if gatewayRefreshes[provider] == nil, contextStore.provider == provider {
            gatewayRefreshes[provider] = Task { await self.refreshGateways(provider) }
        }
        modelLoads[provider] = (load, (modelLoads[provider]?.waiters ?? 0) + 1)
        let result = await withTaskCancellationHandler {
            await Result { try await load.value }
        } onCancel: {
            Task { await self.leaveModelLoad(load, provider: provider) }
        }
        if modelLoads[provider]?.task == load { modelLoads[provider] = nil }
        if generation != modelGeneration, !Task.isCancelled, contextStore.provider == provider {
            return try await listedModels(provider, forceRefresh: false)
        }
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
        Self.modelsGeneration.withLock { $0 += 1 }
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

    // MARK: Unity AI Gateway models

    /// The account's gateways: a Databricks account's own, then the workspaces added in Agents settings.
    private func gateways(of account: CodexRuntimeProvider, agentURL: URL) -> [AgentMCPProvider] {
        let own = if case .databricks = account { PiProviderConfiguration.databricksWorkspaceURL(agentURL: agentURL) } else { URL?.none }
        return (own.map { [.account(workspaceURL: $0)] } ?? []) + gatewayWorkspaces(account)
    }

    /// Lists each signed-in gateway's models in Unity Catalog in the background, once per activation or sign-in, so new
    /// ones appear without an app update. Model listings never wait for it: they read `models.json`, and when a gateway's
    /// answer changes `models.json`, model pickers reload. A gateway that does not answer keeps its saved list.
    private func refreshGateways(_ account: CodexRuntimeProvider) async {
        guard let agentURL = try? agentLocator.agentURL(for: account) else { return }
        let signedIn = (try? signedInProviderIDs(account: account)) ?? []
        let gateways = gateways(of: account, agentURL: agentURL).filter { $0.isAccount || signedIn.contains($0.id) }
        await withTaskGroup { group in
            for gateway in gateways {
                group.addTask { try? await self.listGateway(gateway, account: account, agentURL: agentURL) }
            }
        }
        if (try? writeGateways(account)) == true { invalidateModels() }
    }

    /// Lists a gateway's models and saves the answer, joining a listing of the same gateway that is already running.
    private func listGateway(_ gateway: AgentMCPProvider, account: CodexRuntimeProvider, agentURL: URL) async throws {
        let listing = gatewayListings[account]?[gateway.id] ?? Task { try await self.modelServices(gateway, account: account) }
        gatewayListings[account, default: [:]][gateway.id] = listing
        let result = await Result { try await listing.value }
        let isCurrent = gatewayListings[account]?[gateway.id] == listing
        if isCurrent { gatewayListings[account]?[gateway.id] = nil }
        // Every caller that joined sees the listing's failure, such as a sign-in the Models tab must report.
        let services = try result.get()
        // Only the current listing saves: not one superseded by an activation or sign-in, nor a joined caller again.
        guard isCurrent else { return }
        try PiProviderConfiguration.saveGatewayServices(services, providerID: gateway.id, agentURL: agentURL)
    }

    /// The background listing of the account's gateways in this activation, for tests to await.
    func gatewayRefresh(for account: CodexRuntimeProvider) -> Task<Void, Never>? {
        gatewayRefreshes[account]
    }

    /// A gateway's models for Agents settings, on and off, from its saved list; it is listed first when it has none yet
    /// or Agents settings retries. `models.json`, and so Pi, holds only those turned on.
    func gatewayModels(
        for account: CodexRuntimeProvider,
        provider: AgentMCPProvider,
        forceRefresh: Bool
    ) async throws -> [PiProviderConfiguration.DatabricksModel] {
        let agentURL = try agentLocator.agentURL(for: account)
        if forceRefresh || PiProviderConfiguration.gatewayServices(agentURL: agentURL)[provider.id] == nil {
            try await listGateway(provider, account: account, agentURL: agentURL)
            if try writeGateways(account) { invalidateModels() }
        }
        return try PiProviderConfiguration.databricksModels(
            workspaceURL: provider.workspaceURL,
            services: PiProviderConfiguration.gatewayServices(agentURL: agentURL)[provider.id],
            providerID: provider.id
        )
    }

    /// Applies a switch from Agents settings: `models.json` takes the account's choices from the saved lists, with no
    /// network, and model pickers reload.
    func applyGatewayModelChoices(for account: CodexRuntimeProvider) throws {
        try writeGateways(account)
        invalidateModels()
    }

    /// Writes every gateway's models turned on to `models.json` from its saved list (the bundled one before it first
    /// answers), and drops workspaces no longer added. A gateway with every model off keeps its provider (the workspace
    /// and sign-in) without models. Returns whether a gateway's entry changed.
    @discardableResult
    private func writeGateways(_ account: CodexRuntimeProvider) throws -> Bool {
        let agentURL = try agentLocator.agentURL(for: account)
        let saved = PiProviderConfiguration.gatewayServices(agentURL: agentURL)
        let choices = modelChoices(account)
        var providers: [String: JSONValue] = [:]
        for gateway in gateways(of: account, agentURL: agentURL) {
            let models = try PiProviderConfiguration.databricksModels(
                workspaceURL: gateway.workspaceURL,
                services: saved[gateway.id],
                providerID: gateway.id
            )
            providers.merge(PiProviderConfiguration.databricksProviders(
                models,
                choices: choices,
                workspaceURL: gateway.workspaceURL,
                providerID: gateway.id
            )) { $1 }
        }
        var changed = false
        try PiProviderConfiguration.updateProviders(agentURL: agentURL) { current in
            let isGateway = { (id: String) in PiProviderConfiguration.isAddedWorkspace(id) || id == PiProviderConfiguration.databricksProviderIDs[0] }
            changed = current.filter { isGateway($0.key) } != providers
            current = current.filter { !isGateway($0.key) }.merging(providers) { $1 }
        }
        return changed
    }

    private func availableModels(provider: CodexRuntimeProvider) async throws -> [CodexModel] {
        let cwd = try agentLocator.agentURL(for: provider)
        let connection = try await connect(.init(mode: .control, cwd: cwd, arguments: ["--no-session", "--no-tools"]), provider: provider)
        let result = await Result { try await connection.request("get_available_models", timeout: Self.controlTimeout) }
        await close(connection)
        let providerIDs = Set(provider.piProviderIDs)
        let models = try (result.get().objectValue?["models"]?.arrayValue ?? [])
            .compactMap(\.objectValue)
            // A workspace added in Agents settings is named by its host, the only provider IDs with a dot.
            .filter { $0["provider"]?.stringValue.map { providerIDs.contains($0) || PiProviderConfiguration.isAddedWorkspace($0) } == true }
            .compactMap(PiProviderConfiguration.codexModel)
        // The account's own providers come first, so every "first available model" fallback (summary, chat, image
        // analysis) stays on them rather than on another organization's gateway the user did not name.
        let isAdded = { (model: CodexModel) in PiProviderConfiguration.isAddedWorkspace(model.model.prefix { $0 != "/" }) }
        return models.filter { !isAdded($0) } + models.filter(isAdded)
    }

    // MARK: Subscription sign-in (Local Account only)

    /// Signed in when Pi lists a model of that subscription; shares the cached or in-flight listing.
    func accountStatus(for subscription: PiSubscription) async throws -> AccountStatus {
        let models = try await listedModels(.local, forceRefresh: false)
        return AccountStatus(isAuthenticated: models.contains { $0.model.hasPrefix("\(subscription.rawValue)/") })
    }

    /// Runs Pi's own OAuth flow. Cancelling the task closes Pi and its localhost callback server.
    func signIn(_ subscription: PiSubscription, openURL: @escaping @Sendable (URL) async -> Bool) async throws {
        try await login(
            command: "/dahlia-login \(subscription.rawValue)",
            notificationPrefix: "dahlia:",
            account: .local,
            environment: ["DAHLIA_PI_DEVICE_ID": agentLocator.deviceID()],
            openURL: openURL
        )
        await credentialsDidChange()
    }

    func signOut(_ subscription: PiSubscription) async throws {
        try await logout(providerID: subscription.rawValue, account: .local)
        await credentialsDidChange()
    }

    // MARK: MCP sign-in

    /// Signs in to a Unity AI Gateway with the extension's `/databricks-login`; Pi keeps the credential in the account's
    /// `auth.json`. Open chats stop, so the next turn starts a process that connects with it.
    func signIn(
        _ mcpProvider: AgentMCPProvider,
        account: CodexRuntimeProvider,
        openURL: @escaping @Sendable (URL) async -> Bool
    ) async throws {
        try await login(
            command: "/databricks-login \(mcpProvider.workspaceURL.absoluteString)",
            notificationPrefix: "databricks:",
            account: account,
            environment: [:],
            openURL: openURL
        )
        await closeAll(of: account, mode: .chat)
        // The workspace's models become available.
        gatewayRefreshes[account] = nil
        gatewayListings[account]?[mcpProvider.id] = nil
        invalidateModels()
    }

    /// Signs the user in to the connection behind an MCP service (GitHub behind `system.ai.github`, for example), which
    /// the gateway needs before it serves the service's tools. The workspace's own sign-in stays as it is; open chats
    /// stop so the next turn connects to the service again.
    func signInToService(
        _ service: String,
        of mcpProvider: AgentMCPProvider,
        account: CodexRuntimeProvider,
        openURL: @escaping @Sendable (URL) async -> Bool
    ) async throws {
        try await login(
            command: "/databricks-connection-login \(mcpProvider.workspaceURL.absoluteString) \(service)",
            notificationPrefix: "databricks:connection_",
            account: account,
            environment: [:],
            openURL: openURL
        )
        await closeAll(of: account, mode: .chat)
    }

    /// Removes what Pi and the user kept signed in for an account that signs out: its `auth.json` and its secret
    /// environment variables. Its other files, such as chats, stay.
    func removeCredentials(of account: CodexRuntimeProvider) async {
        await closeAll(of: account)
        if let url = try? agentLocator.agentURL(for: account).appending(path: "auth.json") {
            try? FileManager.default.removeItem(at: url)
        }
        PiLaunchSettings.removeSecrets(for: account)
    }

    /// Pi removes a credential without its provider registered, so the generic sign-out serves MCP sign-ins too.
    /// Open chats stop even if the sign-out fails, since the workspace's servers are no longer registered.
    func signOut(_ mcpProvider: AgentMCPProvider, account: CodexRuntimeProvider) async throws {
        do {
            try await logout(providerID: mcpProvider.id, account: account)
        } catch {
            await closeAll(of: account, mode: .chat)
            invalidateModels()
            throw error
        }
        await closeAll(of: account, mode: .chat)
        invalidateModels()
    }

    /// The visible Unity AI Gateway MCP services and descriptions. Pi lists them, so the token stays in Pi.
    func mcpServices(
        _ mcpProvider: AgentMCPProvider,
        account: CodexRuntimeProvider,
        enabledServices: [String] = []
    ) async throws -> [AgentMCPService] {
        let enabled = enabledServices.isEmpty ? "" : " --enabled \(enabledServices.joined(separator: ","))"
        return try await listing(
            [AgentMCPService].self,
            command: "/databricks-mcp-services \(mcpProvider.listingArguments)\(enabled)",
            notification: "databricks:mcp_services",
            account: account
        )
    }

    /// The Unity AI Gateway model services the sign-in can see, as Unity Catalog lists them. Pi lists them, so the
    /// token stays in Pi.
    func modelServices(_ mcpProvider: AgentMCPProvider, account: CodexRuntimeProvider) async throws -> [JSONValue] {
        try await listing(
            [JSONValue].self,
            command: "/databricks-model-services \(mcpProvider.listingArguments)",
            notification: "databricks:model_services",
            account: account
        )
    }

    /// Runs a listing command and follows its notifications: `<name> <JSON>`, `<name>_sign_in_required`, or
    /// `<name>_failed <message>`.
    private func listing<Value: Decodable & Sendable>(
        _: Value.Type,
        command: String,
        notification name: String,
        account: CodexRuntimeProvider
    ) async throws -> Value {
        let cwd = try agentLocator.agentURL(for: account)
        let connection = try await connect(.init(mode: .control, cwd: cwd, arguments: ["--no-session", "--no-tools"]), provider: account)
        let result = await Result {
            // The extension stops listing after 60 seconds.
            try await PiRPCConnection.withTimeout(.seconds(70)) {
                let request = Task { try? await connection.request("prompt", ["message": .string(command)]) }
                defer { request.cancel() }
                for try await event in connection.events {
                    guard let message = Self.notification(event) else { continue }
                    if message.hasPrefix("\(name) ") {
                        return try JSONDecoder().decode(Value.self, from: Data(message.dropFirst(name.count + 1).utf8))
                    } else if message == "\(name)_sign_in_required" {
                        throw CodexAppServerError.notLoggedIn
                    } else if message.hasPrefix("\(name)_failed") {
                        throw CodexAppServerError.rpcError(
                            code: nil,
                            message: String(message.dropFirst("\(name)_failed".count)).trimmingCharacters(in: .whitespaces)
                        )
                    }
                }
                // The stream ends without an answer when Pi exits; only a cancelled caller stops quietly.
                try Task.checkCancellation()
                throw CodexAppServerError.processExited(nil)
            }
        }
        await close(connection)
        return try result.get()
    }

    /// Pi provider IDs with a stored credential in the account's `auth.json`. Only the keys are read.
    func signedInProviderIDs(account: CodexRuntimeProvider) throws -> Set<String> {
        let url = try agentLocator.agentURL(for: account).appending(path: "auth.json")
        guard let data = FileManager.default.contents(atPath: url.path) else { return [] }
        return Set(((try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue ?? [:]).keys)
    }

    /// Runs a sign-in command and follows its notifications: `<prefix>auth_url <url>`, then `<prefix>login_succeeded`
    /// or `<prefix>login_failed <message>`.
    private func login(
        command: String,
        notificationPrefix prefix: String,
        account: CodexRuntimeProvider,
        environment: [String: String],
        openURL: @escaping @Sendable (URL) async -> Bool
    ) async throws {
        let cwd = try agentLocator.agentURL(for: account)
        let connection = try await connect(
            .init(mode: .control, cwd: cwd, arguments: ["--no-session", "--no-tools"], environment: environment),
            provider: account
        )
        let result = await Result {
            try await PiRPCConnection.withTimeout(Self.loginTimeout) {
                let request = Task { try? await connection.request("prompt", ["message": .string(command)]) }
                defer { request.cancel() }
                for try await event in connection.events {
                    guard let message = Self.notification(event) else { continue }
                    if message.hasPrefix("\(prefix)auth_url ") {
                        guard let url = URL(string: String(message.dropFirst("\(prefix)auth_url ".count))),
                              url.scheme?.lowercased() == "https", url.host != nil
                        else { throw CodexAppServerError.invalidProtocolResponse }
                        guard await openURL(url) else { throw CodexAppServerError.loginPageCouldNotOpen }
                    } else if message == "\(prefix)login_succeeded" {
                        return
                    } else if message.hasPrefix("\(prefix)login_failed") {
                        throw CodexAppServerError.loginFailed(String(message.dropFirst("\(prefix)login_failed".count)).nilIfBlank)
                    }
                }
                // The stream ends without an answer when Pi exits; only a cancelled caller stops quietly.
                try Task.checkCancellation()
                throw CodexAppServerError.processExited(nil)
            }
        }
        await close(connection)
        try result.get()
    }

    private func logout(providerID: String, account: CodexRuntimeProvider) async throws {
        let cwd = try agentLocator.agentURL(for: account)
        let connection = try await connect(.init(mode: .control, cwd: cwd, arguments: ["--no-session", "--no-tools"]), provider: account)
        let result = await Result {
            try await connection.request("prompt", ["message": .string("/dahlia-logout \(providerID)")], timeout: Self.controlTimeout)
        }
        await close(connection)
        _ = try result.get()
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
    /// Picks a model the user did not name: among the account's own providers whenever one fits, and only then among the
    /// workspaces added in Agents settings, which serve another organization's gateway.
    nonisolated static func ownProvidersFirst<Value>(_ models: [CodexModel], _ pick: ([CodexModel]) -> Value?) -> Value? {
        pick(models.filter { !PiProviderConfiguration.isAddedWorkspace($0.model.prefix { $0 != "/" }) }) ?? pick(models)
    }

    nonisolated static func resolvedModel(for request: CodexAppServerRequest, in models: [CodexModel]) throws -> CodexModel {
        let suitable = request.requiresImageInput ? models.filter(\.supportsImages) : models
        if let requested = request.model?.nilIfBlank {
            if let match = matchingModel(requested, in: suitable) { return match }
            if request.requiresExactModel { throw CodexAppServerError.requestedModelUnavailable(requested) }
        }
        guard let fallback = ownProvidersFirst(suitable, \.first) else {
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
        return ownProvidersFirst(models.filter { $0.model.hasSuffix("/\(saved)") || $0.model.hasSuffix(".\(saved)") }, \.first)
    }

    /// Models whose API the extension can make enforce the schema (OpenAI Responses, Claude Messages, Gemini).
    nonisolated static func supportsStrictSchema(model: String) -> Bool {
        if ["openai/", "anthropic/", "dahlia/"].contains(where: { model.hasPrefix($0) }) { return true }
        // A Unity AI Gateway (the account's own `databricks`, or a workspace added by host) also serves other models (GLM,
        // Kimi) as OpenAI Responses on its MLflow route, which takes no strict schema.
        let parts = model.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, parts[0] == "databricks" || PiProviderConfiguration.isAddedWorkspace(parts[0]) else { return false }
        return ["system.ai.gpt-", "system.ai.claude-", "system.ai.gemini-"].contains { parts[1].hasPrefix($0) }
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
        let executableURL = try PiBundle.executableURL(for: provider)
        let environment = try launchEnvironment(
            options, provider: provider, agentURL: agentURL, executableURL: executableURL,
            launch: PiLaunchSettings.load(for: provider)
        )
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

    /// Assemble and validate one environment snapshot immediately before starting the process.
    nonisolated static func launchEnvironment(
        _ options: LaunchOptions,
        provider: CodexRuntimeProvider,
        agentURL: URL,
        executableURL: URL,
        launch: PiLaunchSettings,
        secret: (String) -> String? = { KeychainService.load(key: $0) }
    ) throws -> [String: String] {
        // Provider keys in Dahlia's own environment must not override the account's sign-in or reach model-run commands.
        var environment = ProcessInfo.processInfo.environment.filter { key, _ in
            !key.hasSuffix("_API_KEY") && !key.hasSuffix("_AUTH_TOKEN") && !key.hasSuffix("_OAUTH_TOKEN") && !key.hasPrefix("PI_")
        }
        // The user's variables for this account come before what Dahlia sets, which overrides them.
        environment.merge(launch.resolvedEnvironment(for: provider, secret: secret)) { $1 }
        environment["PATH"] = CommandLineToolLocator.searchPath(for: executableURL, environment: environment)
        environment["PI_CODING_AGENT_DIR"] = agentURL.path
        environment["PI_OFFLINE"] = "1"
        environment["PI_SKIP_VERSION_CHECK"] = "1"
        environment["PI_TELEMETRY"] = "0"
        environment["DAHLIA_PI_MODE"] = options.mode.rawValue
        environment["DAHLIA_PI_BRIDGED_PROVIDERS"] = provider.piBridgedProviderIDs.joined(separator: ",")
        environment.merge(options.environment) { $1 }
        if options.mode == .chat {
            let searchPath = environment["PATH"] ?? ""
            guard !PiWorkingDirectory.holdsCommands(options.cwd, searchPath: searchPath, cwd: options.cwd),
                  try !(PiSandbox.overlapsShellStartupFiles(
                      PiSandbox.realPath(options.cwd),
                      isDirectory: true,
                      environment: environment,
                      cwd: options.cwd
                  ))
            else {
                throw CodexAppServerError.launchFailed(L10n.agentWorkingDirectoryNotAllowed)
            }
            environment["DAHLIA_PI_SANDBOX"] = try String(decoding: JSONEncoder().encode(
                PiSandbox.command(
                    cwd: options.cwd, agentURL: agentURL, piExecutableURL: executableURL,
                    fileAccess: options.fileAccess, searchPath: searchPath, environment: environment
                )
            ), as: UTF8.self)
            environment["DAHLIA_PI_SANDBOX_HIDDEN_ENV"] = try String(
                decoding: JSONEncoder().encode(launch.variables.filter(\.isSecret).map(\.name)),
                as: UTF8.self
            )
            environment["DAHLIA_PI_SANDBOX_TMPDIR"] = PiSandbox.temporaryDirectory.path
            environment["TMPDIR"] = PiSandbox.piTemporaryDirectory.path
        }
        return environment
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
