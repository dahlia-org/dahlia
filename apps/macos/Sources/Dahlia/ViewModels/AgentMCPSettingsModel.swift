import Foundation
import Observation

/// The open account's Unity AI Gateway sign-ins (Databricks workspaces) and the MCP servers registered on them. Pi
/// stores each sign-in's credential; this model saves only the registrations and asks Pi to sign in, list, or sign out.
@MainActor
@Observable
final class AgentMCPSettingsModel {
    let account: CodexRuntimeProvider
    private(set) var settings: AgentMCPSettings
    private(set) var signedInProviderIDs: Set<String> = []
    /// A Databricks account's own workspace, whose Unity AI Gateway serves its models too.
    private(set) var accountProvider: AgentMCPProvider?
    /// The sign-in in progress, from adding a workspace or signing in again.
    private(set) var signingInProviderID: String?
    private(set) var removingProviderID: String?
    /// Providers whose services are being listed, and the last listing's failure for each.
    private(set) var listingProviderIDs: Set<String> = []
    private(set) var listingErrors: [String: any Error] = [:]
    private var pendingServiceRefreshIDs: Set<String> = []
    /// Live credential states only; a saved catalog must not imply a current sign-in.
    private var serviceSignInStates: [String: [String: AgentMCPService.SignInState]] = [:]
    var errorMessage: String?

    private let service: PiRuntimeService
    private let urlOpener: any CodexLoginURLOpening
    private let defaults: UserDefaults
    private let accountWorkspaceURL: @Sendable (UUID) async throws -> URL

    init(
        account: CodexRuntimeProvider,
        service: PiRuntimeService = .shared,
        urlOpener: any CodexLoginURLOpening = WorkspaceCodexLoginURLOpener(),
        defaults: UserDefaults = .standard,
        accountWorkspaceURL: @escaping @Sendable (UUID) async throws -> URL = { connectionID in
            let databricks = DatabricksOAuthService.shared
            return try await databricks.normalizedWorkspaceURL(databricks.connection(id: connectionID).host)
        }
    ) {
        self.account = account
        self.service = service
        self.urlOpener = urlOpener
        self.defaults = defaults
        self.accountWorkspaceURL = accountWorkspaceURL
        settings = AgentMCPSettings.load(for: account, defaults: defaults)
    }

    /// The workspaces MCP servers can be added from: the account's own first, then those signed in to for MCP.
    var selectableProviders: [AgentMCPProvider] {
        (accountProvider.map { [$0] } ?? settings.providers.filter(\.isAccount)) + settings.providers.filter { !$0.isAccount }
    }

    /// The account's own workspace needs no sign-in here; it uses the account's.
    func isSignedIn(_ provider: AgentMCPProvider) -> Bool {
        provider.isAccount || signedInProviderIDs.contains(provider.id)
    }

    /// Finds a Databricks account's own workspace, so its MCPs can be added too.
    func loadAccountProvider() async {
        guard case let .databricks(connectionID) = account, let url = try? await accountWorkspaceURL(connectionID) else { return }
        accountProvider = .account(workspaceURL: url)
    }

    var isBusy: Bool {
        signingInProviderID != nil || removingProviderID != nil
    }

    func servers(of provider: AgentMCPProvider) -> [AgentMCPServer] {
        settings.servers.filter { $0.providerID == provider.id }
    }

    /// Reads which sign-ins Pi holds a credential for. A held credential can still fail to refresh; chat reports that.
    func refreshSignInState() async {
        signedInProviderIDs = await (try? service.signedInProviderIDs(account: account)) ?? []
    }

    /// Signs in to a new workspace and saves it. A workspace already registered signs in again; nothing is saved if
    /// the sign-in fails. The account's own workspace uses the account's sign-in, so it is not added again.
    func addWorkspace(workspaceURL: String) async throws -> AgentMCPProvider {
        let url = try DatabricksOAuthService.shared.normalizedWorkspaceURL(workspaceURL)
        // Chat tells a workspace's provider from Pi's own (`openai`, `databricks`) by the dot in its host.
        guard url.host()?.contains(".") == true else { throw CodexConfigurationError.invalidDatabricksWorkspaceURL }
        // Read the account's workspace here, not from the tab's copy, which may not be loaded or may have failed.
        if case let .databricks(connectionID) = account,
           try await AgentMCPProvider.account(workspaceURL: accountWorkspaceURL(connectionID)).host == url.host() {
            throw AgentMCPSettingsError(message: L10n.mcpWorkspaceIsAccount)
        }
        if let existing = settings.providers.first(where: { $0.workspaceURL == url && !$0.isAccount }) {
            try await signIn(existing)
            return existing
        }
        let provider = AgentMCPProvider(workspaceURL: url)
        try await signIn(provider)
        settings.providers.append(provider)
        settings.save(for: account, defaults: defaults)
        return provider
    }

    func signIn(_ provider: AgentMCPProvider) async throws {
        signingInProviderID = provider.id
        serviceSignInStates[provider.id] = nil
        defer { signingInProviderID = nil }
        try await service.signIn(provider, account: account) { url in
            await self.openLoginURL(url)
        }
        await refreshSignInState()
    }

    private func openLoginURL(_ url: URL) -> Bool {
        urlOpener.open(url)
    }

    /// Opens the sign-in of the connection behind a service, such as GitHub, in the browser.
    func signInToService(_ service: String, of provider: AgentMCPProvider) async throws {
        try await self.service.signInToService(service, of: provider, account: account) { url in
            await self.openLoginURL(url)
        }
        await refreshServices(of: provider)
    }

    /// The MCP services the workspace's Unity AI Gateway offers this sign-in, by full name.
    func services(of provider: AgentMCPProvider) async throws -> [AgentMCPService] {
        try await service.mcpServices(
            provider,
            account: account,
            enabledServices: servers(of: provider).map(\.service).filter(AgentMCPService.requiresUserSignIn)
        )
    }

    /// The provider's services as last listed, with any registered service the listing no longer shows.
    func listedServices(of provider: AgentMCPProvider) -> [String] {
        Array(Set((settings.listedServices?[provider.id] ?? [])
                + (settings.manualServices?[provider.id] ?? []) + servers(of: provider).map(\.service))).sorted()
    }

    func comment(for service: String, of provider: AgentMCPProvider) -> String? {
        settings.serviceComments?[provider.id]?[service]
    }

    func signInState(for service: String, of provider: AgentMCPProvider) -> AgentMCPService.SignInState {
        guard servers(of: provider).contains(where: { $0.service == service }) else { return .unknown }
        return serviceSignInStates[provider.id]?[service] ?? .unknown
    }

    /// Lists the provider's services again and keeps the result; a failure keeps the last list and is reported.
    func refreshServices(of provider: AgentMCPProvider) async {
        guard !listingProviderIDs.contains(provider.id) else {
            pendingServiceRefreshIDs.insert(provider.id)
            return
        }
        listingProviderIDs.insert(provider.id)
        defer {
            listingProviderIDs.remove(provider.id)
            pendingServiceRefreshIDs.remove(provider.id)
        }
        repeat {
            pendingServiceRefreshIDs.remove(provider.id)
            serviceSignInStates[provider.id] = nil
            do {
                let services = try await self.services(of: provider)
                try Task.checkCancellation()
                // A workspace removed while it was listed keeps no list.
                guard selectableProviders.contains(provider) else { return }
                listingErrors[provider.id] = nil
                serviceSignInStates[provider.id] = Dictionary(uniqueKeysWithValues: services.map { ($0.name, $0.signInState ?? .unknown) })
                settings.listedServices = (settings.listedServices ?? [:]).merging([provider.id: services.map(\.name).sorted()]) { $1 }
                settings.serviceComments = (settings.serviceComments ?? [:]).merging([
                    provider.id: services.reduce(into: settings.serviceComments?[provider.id] ?? [:]) { comments, service in
                        if service.metadataUnavailable != true { comments[service.name] = service.comment?.nilIfBlank }
                    },
                ]) { $1 }
                settings.save(for: account, defaults: defaults)
            } catch is CancellationError {
                // Leaving the tab stops the listing and any queued follow-up; the last list stays.
                return
            } catch {
                listingErrors[provider.id] = error
            }
        } while pendingServiceRefreshIDs.contains(provider.id) && !Task.isCancelled
    }

    /// Registers an explicitly named Unity Catalog service without enumerating other schemas.
    func addService(_ input: String, to provider: AgentMCPProvider) throws {
        let service = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = service.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.count <= 255 && $0.wholeMatch(of: /[A-Za-z0-9_-]+/) != nil }) else {
            throw AgentMCPSettingsError(message: L10n.mcpServiceNameInvalid)
        }
        try setService(service, enabled: true, of: provider)
        var manual = settings.manualServices ?? [:]
        manual[provider.id] = Array(Set((manual[provider.id] ?? []) + [service])).sorted()
        settings.manualServices = manual
        settings.save(for: account, defaults: defaults)
    }

    /// Turns a service on with a name of its own (`github`, then `github_2`, ...), or off, removing its server.
    func setService(_ service: String, enabled: Bool, of provider: AgentMCPProvider) throws {
        if enabled {
            guard !servers(of: provider).contains(where: { $0.service == service }) else { return }
            try addServers([service: settings.defaultName(for: service)], to: provider)
        } else if let server = servers(of: provider).first(where: { $0.service == service }) {
            remove(server)
        }
    }

    /// Registers servers on a workspace, keyed by service with each one's server name. Nothing is saved if a name is
    /// invalid, taken, or given twice.
    func addServers(_ names: [String: String], to provider: AgentMCPProvider) throws {
        var added = settings
        // The account's own workspace is saved with its first server, so chat knows its URL.
        if !added.providers.contains(where: { $0.id == provider.id }) { added.providers.append(provider) }
        for (service, name) in names.sorted(by: { $0.key < $1.key }) {
            if let error = added.nameError(name) { throw AgentMCPSettingsError(message: error) }
            added.servers.append(AgentMCPServer(id: .v7(), name: name, providerID: provider.id, service: service))
        }
        settings = added
        settings.save(for: account, defaults: defaults)
    }

    func remove(_ server: AgentMCPServer) {
        settings.servers.removeAll { $0.id == server.id }
        // The account's own workspace stays only while it has servers; its sign-in is the account's, so nothing signs out.
        let servers = settings.servers
        settings.providers.removeAll { provider in provider.isAccount && !servers.contains { $0.providerID == provider.id } }
        settings.save(for: account, defaults: defaults)
    }

    /// Removes the workspace with its servers, then signs out so Pi deletes its credential. The removal does not wait
    /// for Pi, so a Pi that cannot start does not keep the workspace; its sign-out failure is reported.
    func remove(_ provider: AgentMCPProvider) async {
        removingProviderID = provider.id
        defer { removingProviderID = nil }
        errorMessage = nil
        settings.servers.removeAll { $0.providerID == provider.id }
        settings.providers.removeAll { $0.id == provider.id }
        settings.listedServices?[provider.id] = nil
        settings.serviceComments?[provider.id] = nil
        settings.manualServices?[provider.id] = nil
        serviceSignInStates[provider.id] = nil
        settings.save(for: account, defaults: defaults)
        // Its models leave models.json now, even if the sign-out below fails and its credential stays.
        try? await service.applyGatewayModelChoices(for: account)
        do {
            try await service.signOut(provider, account: account)
        } catch {
            errorMessage = error.localizedDescription
        }
        await refreshSignInState()
    }
}

struct AgentMCPSettingsError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
