import AppKit
import SwiftUI

/// Chat agent settings for the open account: how it runs Pi and with which providers (General), models, and its MCP
/// servers. The tabs look like the meeting page's.
struct AgentSettingsView: View {
    @State private var workspaceSettings = WorkspaceAISettingsModel.shared

    var body: some View {
        let account = CodexRuntimeProvider(
            accountConnectionID: workspaceSettings.accountConnectionID,
            databricksConnectionID: workspaceSettings.databricksAccountConnectionID
        )
        AgentSettingsTabs(account: account)
            .id(account)
    }
}

private struct AgentSettingsTabs: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general
        case models
        case mcps

        var id: Self { self }

        var label: String {
            switch self {
            case .general: L10n.general
            case .models: L10n.agentModels
            case .mcps: L10n.agentMCPs
            }
        }
    }

    let account: CodexRuntimeProvider
    @Environment(MainWindowNavigation.self) private var navigation
    @State private var selection = Tab.general
    /// Shared by General's providers and the MCP tab, so a provider added in one shows in the other.
    @State private var mcp: AgentMCPSettingsModel
    @State private var launch: PiLaunchSettingsModel
    /// The Local Account's subscriptions, which only it can sign in to.
    @State private var subscriptions: [CodexAccountController]

    init(account: CodexRuntimeProvider) {
        self.account = account
        _mcp = State(initialValue: AgentMCPSettingsModel(account: account))
        _launch = State(initialValue: PiLaunchSettingsModel(account: account))
        _subscriptions = State(initialValue: account == .local ? PiSubscription.allCases.map { CodexAccountController(subscription: $0) } : [])
    }

    /// Models are set only for Unity AI Gateways: a Databricks account's own and the workspaces added under General.
    /// Subscriptions and the Dahlia Server list their own.
    private var tabs: [Tab] {
        if case .databricks = account { return Tab.allCases }
        return mcp.settings.providers.contains { !$0.isAccount } ? Tab.allCases : Tab.allCases.filter { $0 != .models }
    }

    var body: some View {
        VStack(spacing: 0) {
            // In a grouped form's header, the tabs share the column of the settings title and the sections below.
            Form {
                Section {
                    EmptyView()
                } header: {
                    UnderlineTabBar(tabs: tabs, selection: $selection, label: \.label, accessibilityLabel: L10n.agents)
                }
            }
            .formStyle(.grouped)
            .fixedSize(horizontal: false, vertical: true)

            switch selection {
            case .general:
                Form {
                    AgentRuntimeSection(provider: account)
                    AgentEnvironmentSection(model: launch)
                    AgentProviderSection(account: account, model: mcp, subscriptions: subscriptions, onAdd: presentProviderRegistration)
                }
                .formStyle(.grouped)
            case .models:
                AgentModelSettingsView(account: account, mcp: mcp)
            case .mcps:
                AgentMCPSettingsView(model: mcp, onAdd: presentMCPRegistration)
            }
        }
        .task {
            await mcp.refreshSignInState()
            await mcp.loadAccountProvider()
        }
        // Removing the last added workspace takes the Models tab away.
        .onChange(of: tabs) { if !tabs.contains(selection) { selection = .general } }
        .onDisappear { navigation.dismissSettingsModal() }
    }

    /// Modals cover the whole window, as the sign-in does.
    private func presentProviderRegistration() {
        navigation.presentSettingsModal(
            AgentProviderRegistrationView(model: mcp, subscriptions: subscriptions, onClose: navigation.dismissSettingsModal)
        )
    }

    private func presentMCPRegistration() {
        navigation.presentSettingsModal(AgentMCPRegistrationView(onClose: navigation.dismissSettingsModal))
    }
}

/// How the account runs Pi. The Pi command belongs to the account; the Pi that Dahlia installs is shared by every
/// account on this Mac.
private struct AgentRuntimeSection: View {
    let provider: CodexRuntimeProvider
    @AppStorage private var piPath: String
    @State private var resolvedCommand: Result<String, CodexAppServerError>?
    /// The version of the Pi that Dahlia installed, and whether this account runs it.
    @State private var installedVersion: String?
    @State private var usesInstalledPi = false
    @State private var isInstalling = false
    @State private var installResult: Result<String, Error>?

    init(provider: CodexRuntimeProvider) {
        self.provider = provider
        _piPath = AppStorage(wrappedValue: PiBundle.defaultCommand, PiBundle.executablePathDefaultsKey(for: provider))
    }

    var body: some View {
        Section {
            TextField(L10n.piCommand, text: $piPath, prompt: Text(PiBundle.defaultCommand))
            LabeledContent(L10n.piCommandInUse) {
                switch resolvedCommand {
                case let .success(path):
                    Text(path).textSelection(.enabled)
                case let .failure(error):
                    Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                case nil:
                    EmptyView()
                }
            }
            // Installing helps users without a pi of their own; the installed Pi is used only once chosen as the path.
            if let installedVersion {
                LabeledContent(L10n.piInstalledVersion(installedVersion)) {
                    if isInstalling {
                        ProgressView().controlSize(.small)
                    } else if usesInstalledPi {
                        Button(L10n.updatePi) { startInstall() }
                    } else {
                        Button(L10n.useInstalledPi) { piPath = PiInstaller.executableURL.path }
                    }
                }
            } else if case .failure = resolvedCommand {
                LabeledContent(L10n.piNotInstalled) {
                    if isInstalling {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(L10n.installPi) { startInstall() }
                    }
                }
            }
            switch installResult {
            case let .success(message):
                Text(message).foregroundStyle(.secondary)
            case let .failure(error):
                Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case nil:
                EmptyView()
            }
        } header: {
            Text(L10n.agentRuntime)
        }
        .task(id: piPath) {
            await resolveCommand()
        }
    }

    /// Resolving checks the disk, so it runs off MainActor; Pi reads the saved path when each process starts.
    private func resolveCommand() async {
        let (resolved, version, usesInstalled) = await Task.detached { [provider] in
            let url = Result { try PiBundle.executableURL(for: provider) }
                .mapError { $0 as? CodexAppServerError ?? .piCommandNotFound(nil) }
            // A link on PATH to the Pi that Dahlia installed, as the README suggests, still counts as that Pi.
            let usesInstalled = (try? url.get().resolvingSymlinksInPath()) == PiInstaller.executableURL.resolvingSymlinksInPath()
            return (url.map(\.path), PiInstaller.installedVersion(), usesInstalled)
        }.value
        // An edit cancels this task, but the detached lookup still finishes; drop its now-stale result.
        guard !Task.isCancelled else { return }
        resolvedCommand = resolved
        installedVersion = version
        usesInstalledPi = usesInstalled
    }

    private func startInstall() {
        // Set before the task starts so a second click cannot start another install.
        isInstalling = true
        Task { await installLatestPi() }
    }

    private func installLatestPi() async {
        installResult = nil
        let pathAtStart = piPath
        do {
            let release = try await PiInstaller.release()
            if release.version == installedVersion {
                installResult = .success(L10n.piUpToDate(release.version))
            } else {
                let isFirstInstall = installedVersion == nil
                try await PiInstaller.install(release)
                installResult = .success(L10n.piInstalled(release.version))
                // Install is offered only when this account has no working pi, so it takes the one it asked for,
                // unless the user chose another path while Pi was downloading.
                if isFirstInstall, piPath == pathAtStart { piPath = PiInstaller.executableURL.path }
            }
        } catch {
            installResult = .failure(error)
        }
        isInstalling = false
        await resolveCommand()
    }
}

/// Environment variables for every Pi process the account starts. Secret values go to the Keychain and are never shown.
private struct AgentEnvironmentSection: View {
    let model: PiLaunchSettingsModel
    @State private var errorMessage: String?

    var body: some View {
        Section {
            ForEach(model.settings.variables) { variable in
                AgentEnvironmentVariableRow(
                    variable: variable,
                    isStored: model.storedSecretIDs.contains(variable.id),
                    model: model,
                    onError: { errorMessage = $0 }
                )
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        } header: {
            AgentSectionHeader(title: L10n.agentEnvironment) {
                Button(L10n.agentAddVariable, systemImage: "plus") { model.addVariable() }
            }
        }
        .task { await model.refreshStoredSecrets() }
    }
}

private struct AgentEnvironmentVariableRow: View {
    let variable: PiLaunchSettings.Variable
    let isStored: Bool
    let model: PiLaunchSettingsModel
    let onError: (String?) -> Void
    /// A new secret value, saved when the field is submitted or loses focus, then cleared.
    @State private var secretValue = ""
    @FocusState private var isSecretFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField(
                    L10n.agentVariableName,
                    text: Binding { variable.name } set: { model.setName($0, of: variable.id) },
                    prompt: Text("VARIABLE_NAME")
                )
                .labelsHidden()
                .font(.body.monospaced())
                if variable.isSecret {
                    SecureField(
                        L10n.agentVariableValue,
                        text: $secretValue,
                        prompt: Text(isStored ? L10n.agentSecretStored : L10n.agentVariableValue)
                    )
                    .labelsHidden()
                    .focused($isSecretFocused)
                    .onSubmit(saveSecret)
                    .onChange(of: isSecretFocused) { _, focused in
                        if !focused { saveSecret() }
                    }
                } else {
                    TextField(
                        L10n.agentVariableValue,
                        text: Binding { variable.value ?? "" } set: { model.setValue($0, of: variable.id) },
                        prompt: Text(L10n.agentVariableValue)
                    )
                    .labelsHidden()
                }
                Button(
                    variable.isSecret ? L10n.agentVariableMakePlain : L10n.agentVariableMakeSecret,
                    systemImage: variable.isSecret ? "lock.fill" : "lock.open"
                ) {
                    toggleSecret()
                }
                .labelStyle(.iconOnly)
                .help(variable.isSecret ? L10n.agentVariableMakePlain : L10n.agentVariableMakeSecret)
                Button(L10n.delete, systemImage: "xmark") {
                    Task { await model.removeVariable(variable.id) }
                }
                .labelStyle(.iconOnly)
                .help(L10n.delete)
            }
            if !variable.name.isEmpty, !PiLaunchSettings.isValidName(variable.name) {
                Text(L10n.agentVariableNameInvalid)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func saveSecret() {
        let value = secretValue
        guard !value.isEmpty else { return }
        secretValue = ""
        Task {
            do {
                try await model.setSecretValue(value, of: variable.id)
                onError(nil)
            } catch {
                onError(error.localizedDescription)
            }
        }
    }

    private func toggleSecret() {
        Task {
            do {
                try await model.setSecret(!variable.isSecret, of: variable.id)
                onError(nil)
            } catch {
                onError(error.localizedDescription)
            }
        }
    }
}

/// The providers the open account's agent can use, each with a badge for what it serves: the account's own sign-in,
/// the subscriptions signed in to (Local Account), and the Databricks workspaces signed in to for MCP servers.
private struct AgentProviderSection: View {
    let account: CodexRuntimeProvider
    let model: AgentMCPSettingsModel
    let subscriptions: [CodexAccountController]
    let onAdd: () -> Void
    @State private var signInTask: Task<Void, Never>?
    @State private var pendingRemoval: AgentMCPProvider?

    private var signedInSubscriptions: [CodexAccountController] {
        subscriptions.filter { $0.accountStatus?.isAuthenticated == true }
    }

    private var workspaces: [AgentMCPProvider] {
        model.settings.providers.filter { !$0.isAccount }
    }

    var body: some View {
        Section {
            switch account {
            case .local:
                EmptyView()
            case .databricks:
                // The account signs in and out from the account menu.
                // Until its workspace is known, the account's provider shows without a host.
                AgentProviderRow(
                    title: model.accountProvider.map { L10n.unityGatewayHost($0.host) } ?? L10n.databricksUnityGateway,
                    icon: .databricksLogo,
                    uses: [L10n.agentProviderModels, L10n.mcp]
                ) {
                    EmptyView()
                }
                // Dahlia does not know whether the account's own sign-in still holds, so the row shows no status.
                .help(L10n.agentProviderAccountSignIn)
            case .dahlia:
                AgentProviderRow(
                    title: L10n.dahliaAccount,
                    icon: Image(nsImage: NSApplication.shared.applicationIconImage),
                    uses: [L10n.agentProviderModels]
                ) {
                    EmptyView()
                }
                .help(L10n.agentProviderAccountSignIn)
            }
            ForEach(signedInSubscriptions, id: \.subscription) { controller in
                AgentProviderRow(
                    title: controller.subscription.displayName,
                    icon: controller.subscription.logo,
                    uses: [L10n.agentProviderModels]
                ) {
                    if controller.isSigningOut {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(L10n.codexSignedIn).foregroundStyle(.secondary)
                    }
                    AgentProviderActions {
                        Button(L10n.signOut) { Task { await controller.signOut() } }
                    }
                    .disabled(controller.isBusy)
                }
            }
            ForEach(workspaces) { provider in
                AgentProviderRow(title: L10n.unityGatewayHost(provider.host), icon: .databricksLogo, uses: [L10n.agentProviderModels, L10n.mcp]) {
                    if model.signingInProviderID == provider.id, signInTask != nil {
                        ProgressView().controlSize(.small)
                        Button(L10n.cancelSignIn) { signInTask?.cancel() }
                    } else if model.isSignedIn(provider) {
                        Text(L10n.codexSignedIn).foregroundStyle(.secondary)
                    } else {
                        Button(L10n.dahliaSignIn) { signIn(provider) }
                            .disabled(model.isBusy)
                    }
                    AgentProviderActions {
                        if model.isSignedIn(provider) {
                            Button(L10n.signInAgain) { signIn(provider) }
                        }
                        Button(L10n.delete, role: .destructive) { pendingRemoval = provider }
                    }
                    .disabled(model.isBusy)
                }
            }
            if account == .local, signedInSubscriptions.isEmpty, workspaces.isEmpty {
                Text(L10n.agentProvidersEmpty).foregroundStyle(.secondary)
            }
            ForEach(subscriptions.compactMap(\.errorMessage) + [model.errorMessage].compactMap(\.self), id: \.self) { message in
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        } header: {
            AgentSectionHeader(title: L10n.agentProviders) {
                Button(L10n.addProvider, systemImage: "plus", action: onAdd)
                    .disabled(model.isBusy)
            }
        }
        .confirmationDialog(
            pendingRemoval.map { L10n.mcpRemoveWorkspace($0.host) } ?? "",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button(L10n.delete, role: .destructive) {
                guard let provider = pendingRemoval else { return }
                pendingRemoval = nil
                Task { await model.remove(provider) }
            }
            Button(L10n.cancel, role: .cancel) { pendingRemoval = nil }
        } message: {
            Text(L10n.mcpRemoveWorkspaceDescription)
        }
        .task {
            for controller in subscriptions {
                await controller.activate()
            }
        }
        // A sign-in made elsewhere (setup tour or the add modal) updates the subscriptions too.
        .onReceive(NotificationCenter.default.publisher(for: PiRuntimeService.modelsDidChange).receive(on: RunLoop.main)) { _ in
            Task {
                for controller in subscriptions where !controller.isBusy {
                    await controller.activate()
                }
            }
        }
        .onDisappear { signInTask?.cancel() }
    }

    private func signIn(_ provider: AgentMCPProvider) {
        model.errorMessage = nil
        signInTask = Task {
            do {
                try await model.signIn(provider)
            } catch is CancellationError {
                // Cancelling closes Pi and its pending sign-in.
            } catch {
                model.errorMessage = error.localizedDescription
            }
            signInTask = nil
        }
    }
}

/// A section title with the section's add button beside it.
private struct AgentSectionHeader<Action: View>: View {
    let title: String
    @ViewBuilder let action: Action

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            action
        }
    }
}

/// One provider: its logo and name with a badge for each use (models, MCP), and its status and actions.
struct AgentProviderRow<Trailing: View>: View {
    let title: String
    let icon: Image
    let uses: [String]
    @ViewBuilder let trailing: Trailing

    var body: some View {
        LabeledContent {
            HStack { trailing }
        } label: {
            Label {
                HStack(spacing: 6) {
                    Text(title)
                    ForEach(uses, id: \.self) { use in
                        Text(use)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .dahliaChipSurface()
                    }
                }
            } icon: {
                icon.resizable().scaledToFit().frame(width: 16, height: 16)
            }
        }
    }
}

/// A row's less frequent actions, as the workspace settings show them.
struct AgentProviderActions<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Menu(L10n.actions, systemImage: "ellipsis.circle") { content }
            .labelStyle(.iconOnly)
            .dahliaFixedSymbol()
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L10n.actions)
    }
}

extension PiSubscription {
    var logo: Image {
        switch self {
        case .openai: .openAILogo
        case .anthropic: .anthropicLogo
        }
    }
}

/// The account's Unity AI Gateway models, under each gateway's provider row as the MCP tab groups services: the
/// Databricks account's own gateway and the workspaces added under General. Each model turns on or off with a switch;
/// only those turned on go to the account's `models.json`, so Pi, and with it the chat, summary, and image analysis model
/// pickers, knows only them.
private struct AgentModelSettingsView: View {
    let account: CodexRuntimeProvider
    let mcp: AgentMCPSettingsModel
    private let service = PiRuntimeService.shared
    /// Each provider's models by provider ID, as last listed.
    @State private var models: [String: [PiProviderConfiguration.DatabricksModel]] = [:]
    @State private var choices: [String: Bool] = [:]
    @State private var loadingProviderIDs: Set<String> = []
    @State private var errors: [String: String] = [:]
    @State private var expandedProviderIDs: Set<String> = []

    /// Models on in the Databricks account's own gateway.
    private var ownOnCount: Int {
        let own = PiProviderConfiguration.databricksProviderIDs[0]
        return (models[own] ?? []).count(where: { $0.isOn(shownChoices(own)) })
    }

    /// The switches as `models.json` applies them: an own gateway that lost the model kept on shows its default on.
    private func shownChoices(_ providerID: String) -> [String: Bool] {
        PiProviderConfiguration.effectiveChoices(choices, for: models[providerID] ?? [])
    }

    var body: some View {
        Form {
            ForEach(mcp.selectableProviders) { provider in
                let providerModels = models[provider.id] ?? []
                Section {
                    DisclosureGroup(isExpanded: expansion(of: provider)) {
                        if loadingProviderIDs.contains(provider.id), providerModels.isEmpty {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text(L10n.chatModelLoading).foregroundStyle(.secondary)
                            }
                        }
                        if let error = errors[provider.id] {
                            HStack {
                                Label(error, systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer()
                                Button(L10n.retry) { Task { await load(provider, forceRefresh: true) } }
                                    .disabled(loadingProviderIDs.contains(provider.id))
                            }
                        } else if !loadingProviderIDs.contains(provider.id), providerModels.isEmpty {
                            Text(L10n.codexNoModels).foregroundStyle(.secondary)
                        }
                        ForEach(providerModels, id: \.reference) { model in
                            let isOn = model.isOn(shownChoices(provider.id))
                            LabeledContent {
                                Toggle(model.name, isOn: on(model, of: provider))
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    // A chat needs a model, so a Databricks account keeps one on in its own gateway:
                                    // its other models come from workspaces that can be removed.
                                    .disabled(isOn && provider.isAccount && ownOnCount == 1)
                            } label: {
                                HStack(spacing: 4) {
                                    // A model turned off reads fainter.
                                    Text(model.name).foregroundStyle(isOn ? .primary : .secondary)
                                    AgentModelDetailsButton(model: model)
                                }
                            }
                        }
                    } label: {
                        AgentProviderRow(title: L10n.unityGatewayHost(provider.host), icon: .databricksLogo, uses: []) {
                            if !providerModels.isEmpty {
                                Text(L10n.agentEnabledCount(providerModels.count(where: { $0.isOn(shownChoices(provider.id)) })))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        // The whole row opens and closes the list, not just the arrow.
                        .contentShape(.rect)
                        .onTapGesture { expansion(of: provider).wrappedValue.toggle() }
                        .accessibilityAddTraits(.isButton)
                    }
                }
            }
        }
        .formStyle(.grouped)
        // The account's own workspace is found after the tab opens.
        .task(id: mcp.selectableProviders) {
            choices = AgentModelSettings.choices(for: account)
            await withTaskGroup { group in
                for provider in mcp.selectableProviders where models[provider.id] == nil {
                    group.addTask { await load(provider, forceRefresh: false) }
                }
            }
        }
        // A background listing saved a gateway's new answer; the saved lists read with no network.
        .onReceive(NotificationCenter.default.publisher(for: PiRuntimeService.modelsDidChange).receive(on: RunLoop.main)) { _ in
            Task {
                for provider in mcp.selectableProviders where models[provider.id] != nil {
                    await load(provider, forceRefresh: false)
                }
            }
        }
    }

    /// Lists the gateway's models; the last list serves until `forceRefresh`.
    private func load(_ provider: AgentMCPProvider, forceRefresh: Bool) async {
        loadingProviderIDs.insert(provider.id)
        defer { loadingProviderIDs.remove(provider.id) }
        do {
            models[provider.id] = try await service.gatewayModels(for: account, provider: provider, forceRefresh: forceRefresh)
            errors[provider.id] = nil
        } catch is CancellationError {
            // Leaving the tab stops the listing.
        } catch {
            errors[provider.id] = message(error, provider: provider)
        }
    }

    private func message(_ error: any Error, provider: AgentMCPProvider) -> String {
        guard case .notLoggedIn = error as? CodexAppServerError else { return error.localizedDescription }
        // The account signs in from the account menu; other providers sign in under General.
        return provider.isAccount ? L10n.mcpAccountSignInRequired : L10n.mcpProviderSignInRequired
    }

    private func expansion(of provider: AgentMCPProvider) -> Binding<Bool> {
        Binding {
            expandedProviderIDs.contains(provider.id)
        } set: { isExpanded in
            if isExpanded { expandedProviderIDs.insert(provider.id) } else { expandedProviderIDs.remove(provider.id) }
        }
    }

    private func on(_ model: PiProviderConfiguration.DatabricksModel, of provider: AgentMCPProvider) -> Binding<Bool> {
        Binding {
            model.isOn(shownChoices(provider.id))
        } set: { isOn in
            choices[model.reference] = isOn
            AgentModelSettings.setModel(model.reference, on: isOn, for: account)
            Task {
                do {
                    try await service.applyGatewayModelChoices(for: account)
                    errors[provider.id] = nil
                } catch {
                    errors[provider.id] = message(error, provider: provider)
                }
            }
        }
    }
}

/// An info mark that shows, on hover, what `models.json` gives Pi for the model: its ID, API, endpoint, limits, and price.
private struct AgentModelDetailsButton: View {
    let model: PiProviderConfiguration.DatabricksModel
    @State private var isPresented = false

    var body: some View {
        // Hovering shows it; a click, the keyboard, or VoiceOver opens it too.
        Button { isPresented.toggle() } label: {
            Image(systemName: "info.circle")
                .dahliaFixedSymbol()
                .imageScale(.small)
                .foregroundStyle(DahliaDesign.secondaryTextColor)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isPresented = $0 }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(rows, id: \.label) { row in
                    GridRow {
                        Text(row.label).foregroundStyle(.secondary)
                        Text(row.value)
                    }
                }
            }
            .padding(12)
        }
        .accessibilityLabel(L10n.agentModelDetails)
    }

    private var rows: [(label: String, value: String)] {
        let definition = model.definition
        let cost = definition["cost"]?.objectValue ?? [:]
        let efforts = PiProviderConfiguration.reasoningEfforts(model: definition)
        var rows: [(label: String, value: String)] = [
            (L10n.agentModelID, model.id),
            (L10n.agentModelAPI, definition["api"]?.stringValue ?? ""),
            (L10n.agentModelEndpoint, definition["baseUrl"]?.stringValue ?? ""),
            (L10n.agentModelContextWindow, tokens(definition["contextWindow"])),
            (L10n.agentModelMaxOutput, tokens(definition["maxTokens"])),
            (L10n.agentModelInput, (definition["input"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: ", ")),
            (L10n.agentModelReasoning, efforts.isEmpty ? L10n.agentModelReasoningNone : efforts.joined(separator: ", ")),
            (L10n.agentModelPrice, price(cost)),
        ]
        for tier in cost["tiers"]?.arrayValue?.compactMap(\.objectValue) ?? [] {
            rows.append((L10n.agentModelPriceTier(tokenCount(tier["inputTokensAbove"])), price(tier)))
        }
        return rows
    }

    private func tokenCount(_ value: JSONValue?) -> String {
        value?.intValue?.formatted() ?? "-"
    }

    private func tokens(_ value: JSONValue?) -> String {
        L10n.agentModelTokens(tokenCount(value))
    }

    private func price(_ cost: [String: JSONValue]) -> String {
        let value = { (key: String) in cost[key].flatMap { if case let .number(number) = $0 { number.formatted() } else { nil } } ?? "-" }
        return L10n.agentModelPriceValue(value("input"), value("output"), value("cacheRead"), value("cacheWrite"))
    }
}

/// The open account's MCP servers. Each Unity Gateway provider (the account's own and those added under General)
/// expands to its services, each turned on or off with a switch; remote MCP servers are added with the modal.
private struct AgentMCPSettingsView: View {
    let model: AgentMCPSettingsModel
    let onAdd: () -> Void
    @State private var expandedProviderIDs: Set<String> = []
    @State private var serviceSignIn: (service: String, task: Task<Void, Never>)?
    /// Each provider's listing in progress, cancelled when the tab goes away.
    @State private var listings: [String: Task<Void, Never>] = [:]
    @State private var renaming: AgentMCPServer?
    @State private var proposedName = ""

    var body: some View {
        Form {
            ForEach(model.selectableProviders) { provider in
                Section {
                    DisclosureGroup(isExpanded: expansion(of: provider)) {
                        services(of: provider)
                    } label: {
                        // One line reads better beside the disclosure arrow.
                        AgentProviderRow(
                            title: L10n.unityGatewayHost(provider.host),
                            icon: .databricksLogo,
                            uses: [L10n.agentProviderModels, L10n.mcp]
                        ) {
                            Text(L10n.agentEnabledCount(model.servers(of: provider).count))
                                .foregroundStyle(.secondary)
                        }
                        // The whole row opens and closes the list, not just the arrow.
                        .contentShape(.rect)
                        .onTapGesture { expansion(of: provider).wrappedValue.toggle() }
                        .accessibilityAddTraits(.isButton)
                    }
                }
            }
            Section {
                if let errorMessage = model.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Button(L10n.addRemoteMCPServer, action: onAdd)
            }
        }
        .formStyle(.grouped)
        .alert(L10n.mcpRenameServer, isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(L10n.mcpServerName, text: $proposedName)
            Button(L10n.rename, action: rename)
            Button(L10n.cancel, role: .cancel) { renaming = nil }
        }
        .onDisappear {
            serviceSignIn?.task.cancel()
            listings.values.forEach { $0.cancel() }
        }
    }

    @ViewBuilder
    private func services(of provider: AgentMCPProvider) -> some View {
        let services = model.listedServices(of: provider)
        if model.listingProviderIDs.contains(provider.id), services.isEmpty {
            HStack {
                ProgressView().controlSize(.small)
                Text(L10n.mcpLoadingServices).foregroundStyle(.secondary)
            }
        }
        if let error = model.listingErrors[provider.id] {
            HStack {
                Label(listingMessage(error, provider: provider), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(L10n.retry) { list(provider) }
            }
        } else if !model.listingProviderIDs.contains(provider.id), services.isEmpty {
            Text(L10n.mcpNoServices).foregroundStyle(.secondary)
        }
        ForEach(services, id: \.self) { service in
            let server = model.servers(of: provider).first { $0.service == service }
            LabeledContent {
                Toggle(service, isOn: enabled(service, of: provider))
                    .labelsHidden()
                    .toggleStyle(.switch)
                if serviceSignIn?.service == serviceKey(service, of: provider) {
                    ProgressView().controlSize(.small)
                    Button(L10n.cancel) { serviceSignIn?.task.cancel() }
                } else {
                    AgentProviderActions {
                        if let server {
                            Button(L10n.rename) {
                                proposedName = server.name
                                renaming = server
                            }
                        }
                        // The service's own sign-in (GitHub, Slack, ...) at Unity Gateway, needed before its tools work.
                        Button(L10n.mcpServiceSignIn) { signIn(to: service, of: provider) }
                    }
                    .disabled(serviceSignIn != nil)
                }
            } label: {
                Text(server.map { L10n.mcpServiceWithServerName(service, $0.name) } ?? service)
            }
        }
    }

    /// Expanding lists the services again, showing the last list meanwhile.
    private func expansion(of provider: AgentMCPProvider) -> Binding<Bool> {
        Binding {
            expandedProviderIDs.contains(provider.id)
        } set: { isExpanded in
            if isExpanded {
                expandedProviderIDs.insert(provider.id)
                list(provider)
            } else {
                expandedProviderIDs.remove(provider.id)
            }
        }
    }

    /// One listing per provider at a time; a listing already running serves this request too.
    private func list(_ provider: AgentMCPProvider) {
        guard listings[provider.id] == nil else { return }
        listings[provider.id] = Task {
            await model.refreshServices(of: provider)
            listings[provider.id] = nil
        }
    }

    private func enabled(_ service: String, of provider: AgentMCPProvider) -> Binding<Bool> {
        Binding {
            model.servers(of: provider).contains { $0.service == service }
        } set: { isOn in
            do {
                try model.setService(service, enabled: isOn, of: provider)
                model.errorMessage = nil
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }

    private func listingMessage(_ error: any Error, provider: AgentMCPProvider) -> String {
        guard case .notLoggedIn = error as? CodexAppServerError else { return error.localizedDescription }
        // The account signs in from the account menu; other providers sign in under General.
        return provider.isAccount ? L10n.mcpAccountSignInRequired : L10n.mcpProviderSignInRequired
    }

    private func rename() {
        guard let server = renaming else { return }
        renaming = nil
        do {
            try model.rename(server, to: proposedName.trimmingCharacters(in: .whitespacesAndNewlines))
            model.errorMessage = nil
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private func serviceKey(_ service: String, of provider: AgentMCPProvider) -> String {
        "\(provider.id)/\(service)"
    }

    private func signIn(to service: String, of provider: AgentMCPProvider) {
        model.errorMessage = nil
        serviceSignIn = (serviceKey(service, of: provider), Task {
            do {
                try await model.signInToService(service, of: provider)
            } catch is CancellationError {
                // Cancel, or leaving the tab, stops the browser sign-in.
            } catch {
                model.errorMessage = error.localizedDescription
            }
            serviceSignIn = nil
        })
    }
}
