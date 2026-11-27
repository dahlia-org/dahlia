import AppKit
import SwiftUI

/// Agent advanced settings for the open account: Pi, chat, schedules, plugins, and security.
struct AgentSettingsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general
        case schedules
        case packages
        case security

        var id: Self { self }

        var label: String {
            switch self {
            case .general: L10n.general
            case .schedules: L10n.agentSchedules
            case .packages: L10n.agentPackages
            case .security: L10n.agentSecurity
            }
        }
    }

    var body: some View {
        AgentSettingsTabs()
    }
}

private struct AgentSettingsTabs: View {

    @Environment(MainWindowNavigation.self) private var navigation
    @State private var launch = PiLaunchSettingsModel()
    @State private var packages = PiPackageSettingsModel()

    var body: some View {
        @Bindable var navigation = navigation
        VStack(spacing: 0) {
            // In a grouped form's header, the tabs share the column of the settings title and the sections below.
            Form {
                Section {
                    EmptyView()
                } header: {
                    UnderlineTabBar(
                        tabs: AgentSettingsView.Tab.allCases,
                        selection: $navigation.agentSettingsTab,
                        label: \.label,
                        accessibilityLabel: L10n.agentAdvancedSettings
                    )
                }
            }
            .formStyle(.grouped)
            .font(.dahliaBody)
            .fixedSize(horizontal: false, vertical: true)

            switch navigation.agentSettingsTab {
            case .general:
                Form {
                    AgentRuntimeSection(launch: launch)
                    AgentEnvironmentSection(model: launch)
                    AgentChatSettingsSection()
                    AgentChatInstructionsSection()
                    if ProviderAccountDirectory.databricksConnectionID != nil { AgentOmnigentSection() }
                }
                .formStyle(.grouped)
                .font(.dahliaBody)
            case .packages:
                AgentPackageSettingsView(model: packages)
            case .schedules:
                AgentScheduleSettingsView()
            case .security:
                AgentSecuritySettingsView()
            }
        }
        .onDisappear { navigation.dismissSettingsModal() }
    }
}

/// The Models page: each provider's models, summary generation, and image analysis.
struct AgentModelsPageView: View {
    @Environment(MainWindowNavigation.self) private var navigation
    @State private var mcp = AgentMCPSettingsModel()
    /// The Local Account's subscriptions, which only it can sign in to.
    @State private var subscriptions = PiSubscription.allCases.map { PiSubscriptionController(subscription: $0) }

    var body: some View {
        AgentModelSettingsView(mcp: mcp, subscriptions: subscriptions) {
            navigation.openSettings(category: .providers)
        }
        .task {
            await mcp.refreshSignInState()
            mcp.loadAccountProviders()
        }
    }
}

/// The Connectors page: MCP servers from providers and those configured directly.
struct AgentConnectorSettingsView: View {
    @Environment(MainWindowNavigation.self) private var navigation
    @State private var mcp = AgentMCPSettingsModel()

    var body: some View {
        AgentMCPSettingsView(model: mcp, onAdd: presentMCPRegistration) { server in
            navigation.presentSettingsModal(
                AgentMCPDirectServerView(model: mcp, server: server, onClose: navigation.dismissSettingsModal)
            )
        }
        .task {
            await mcp.refreshSignInState()
            mcp.loadAccountProviders()
        }
        .onDisappear { navigation.dismissSettingsModal() }
    }

    private func presentMCPRegistration(_ provider: AgentMCPProvider) {
        navigation.presentSettingsModal(AgentMCPRegistrationView(model: mcp, provider: provider, onClose: navigation.dismissSettingsModal))
    }
}

/// Each account chooses PATH discovery or the Pi installation shared by all accounts on this Mac.
private struct AgentRuntimeSection: View {
    let launch: PiLaunchSettingsModel
    @Environment(MainWindowNavigation.self) private var navigation
    @AppStorage private var useManagedPi: Bool
    @State private var resolvedCommand: Result<String, PiRuntimeError>?
    /// The version of the Pi that Dahlia installed.
    @State private var installedVersion: String?
    @State private var isInstalling = false
    @State private var installResult: Result<String, Error>?

    init(launch: PiLaunchSettingsModel) {
        self.launch = launch
        _useManagedPi = AppStorage(wrappedValue: PiBundle.usesManagedPi(), PiBundle.useManagedPiDefaultsKey())
    }

    var body: some View {
        Section {
            Toggle(L10n.useManagedPi, isOn: $useManagedPi)
                .toggleStyle(.dahliaSwitch)
            LabeledContent(L10n.piCommandInUse) {
                if useManagedPi {
                    Text(PiInstaller.executableURL.path).textSelection(.enabled)
                } else {
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
            }
            if useManagedPi, case let .failure(error) = resolvedCommand {
                Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            if useManagedPi {
                if let installedVersion {
                    LabeledContent(L10n.piInstalledVersion(installedVersion)) {
                        if isInstalling {
                            ProgressView().controlSize(.small)
                        } else {
                            HStack {
                                registryButton
                                Button(L10n.updatePi) { startInstall() }
                            }
                        }
                    }
                } else {
                    LabeledContent(L10n.piNotInstalled) {
                        if isInstalling {
                            ProgressView().controlSize(.small)
                        } else {
                            HStack {
                                registryButton
                                Button(L10n.installPi) { startInstall() }
                            }
                        }
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
                .font(.dahliaSectionHeader)
        }
        .task(id: [String(useManagedPi), String(launch.commandDiscoveryRevision)]) {
            await resolveCommand()
        }
    }

    /// An advanced setting: Pi installs and updates from Dahlia's default registry unless the account names another.
    private var registryButton: some View {
        Button(L10n.piRegistrySettings) {
            navigation.presentSettingsModal(PiRegistryModal(onClose: navigation.dismissSettingsModal))
        }
    }

    /// Resolving checks the disk off MainActor; each new Pi process reads the saved selection.
    private func resolveCommand() async {
        let selection = useManagedPi
        let revision = launch.commandDiscoveryRevision
        resolvedCommand = nil
        let (resolved, version) = await Task.detached {
            let url = Result {
                try PiBundle.executableURL()
            }
            .mapError { $0 as? PiRuntimeError ?? .piCommandNotFound(nil) }
            return (url.map(\.path), PiInstaller.installedVersion())
        }.value
        guard !Task.isCancelled, useManagedPi == selection, launch.commandDiscoveryRevision == revision else { return }
        resolvedCommand = resolved
        installedVersion = version
    }

    private func startInstall() {
        // Set before the task starts so a second click cannot start another install.
        isInstalling = true
        Task { await installLatestPi() }
    }

    private func installLatestPi() async {
        installResult = nil
        do {
            if let installedVersion {
                let version = try await PiInstaller.update()
                installResult = .success(version == installedVersion ? L10n.piUpToDate(version) : L10n.piInstalled(version))
            } else {
                let release = try await PiInstaller.release()
                try await PiInstaller.install(release)
                installResult = .success(L10n.piInstalled(release.version))
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
                .font(.dahliaBody.monospaced())
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
                    .font(.dahliaSecondary)
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
/// The models each provider offers, to turn on or off. Signing in and out of a provider is on the Providers page.
private struct AgentProviderSection<Models: View, SubscriptionModels: View>: View {
    let model: AgentMCPSettingsModel
    let subscriptions: [PiSubscriptionController]
    let onManage: () -> Void
    let enabledCount: (AgentMCPProvider) -> Int?
    @ViewBuilder let modelsContent: (AgentMCPProvider) -> Models
    let subscriptionEnabledCount: (PiSubscriptionController) -> Int
    @ViewBuilder let subscriptionModelsContent: (PiSubscriptionController) -> SubscriptionModels
    @State private var expandedProviderIDs: Set<String> = []
    @State private var hoveredProviderID: String?

    private var signedInSubscriptions: [PiSubscriptionController] {
        subscriptions.filter { $0.accountStatus?.isAuthenticated == true }
    }

    /// Workspaces added before every Databricks connection was a provider account, while Pi still holds their sign-in.
    private var workspaces: [AgentMCPProvider] {
        model.settings.providers.filter { !$0.isAccount && model.isSignedIn($0) }
    }

    var body: some View {
        Section {
            ForEach(model.accountProviders) { provider in
                gatewayRow(provider)
            }
            ForEach(signedInSubscriptions, id: \.subscription) { controller in
                DisclosureGroup(isExpanded: expansion(of: controller.subscription.rawValue)) {
                    subscriptionModelsContent(controller)
                } label: {
                    AgentProviderRow(
                        title: controller.subscription.displayName,
                        icon: controller.subscription.logo,
                        uses: [L10n.agentProviderModels]
                    ) {
                        Text(L10n.agentEnabledCount(subscriptionEnabledCount(controller))).foregroundStyle(.secondary)
                    }
                    .contentShape(.rect)
                    .background(Color.primary.opacity(hoveredProviderID == controller.subscription.rawValue ? 0.06 : 0))
                    .onHover { hoveredProviderID = $0 ? controller.subscription.rawValue : nil }
                    .onTapGesture { expansion(of: controller.subscription.rawValue).wrappedValue.toggle() }
                    .accessibilityAddTraits(.isButton)
                }
            }
            ForEach(workspaces) { provider in
                gatewayRow(provider)
            }
            if signedInSubscriptions.isEmpty, workspaces.isEmpty, model.accountProviders.isEmpty {
                Text(L10n.agentProvidersEmpty).foregroundStyle(.secondary)
            }
            ForEach([model.errorMessage].compactMap(\.self), id: \.self) { message in
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        } header: {
            AgentSectionHeader(title: L10n.agentProviders) {
                Button(L10n.manageProviders, action: onManage)
            }
        }
        .task {
            for controller in subscriptions {
                await controller.activate()
            }
        }
        // A sign-in made on the Providers page or in the setup tour updates the subscriptions too.
        .onReceive(NotificationCenter.default.publisher(for: PiRuntimeService.modelsDidChange).receive(on: RunLoop.main)) { _ in
            Task {
                for controller in subscriptions where !controller.isBusy {
                    await controller.activate()
                }
            }
        }
    }

    /// The provider account behind a gateway, whose name titles it.
    private func connection(of provider: AgentMCPProvider) -> DatabricksConnection? {
        WorkspaceAISettingsModel.shared.databricksConnections.first {
            URL(string: $0.host).map(AgentMCPProvider.id(for:)) == provider.id
        }
    }

    private func gatewayRow(_ provider: AgentMCPProvider) -> some View {
        DisclosureGroup(isExpanded: expansion(of: provider.id)) {
            modelsContent(provider)
        } label: {
            AgentProviderRow(
                title: connection(of: provider)?.displayName ?? L10n.unityGatewayHost(provider.host),
                icon: .databricksLogo,
                uses: [L10n.agentProviderModels, L10n.mcp]
            ) {
                if let count = enabledCount(provider) {
                    Text(L10n.agentEnabledCount(count)).foregroundStyle(.secondary)
                }
            }
            .contentShape(.rect)
            .background(Color.primary.opacity(hoveredProviderID == provider.id ? 0.06 : 0))
            .onHover { hoveredProviderID = $0 ? provider.id : nil }
            .onTapGesture { expansion(of: provider.id).wrappedValue.toggle() }
            .accessibilityAddTraits(.isButton)
        }
    }

    private func expansion(of providerID: String) -> Binding<Bool> {
        Binding {
            expandedProviderIDs.contains(providerID)
        } set: { expanded in
            if expanded { expandedProviderIDs.insert(providerID) } else { expandedProviderIDs.remove(providerID) }
        }
    }
}

/// A section title with the section's add button beside it.
struct AgentSectionHeader<Action: View>: View {
    let title: String
    @ViewBuilder let action: Action

    var body: some View {
        HStack {
            Text(title)
                .font(.dahliaSectionHeader)
            Spacer()
            action
                .font(.dahliaBody)
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
                            .font(.dahliaSecondary)
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

/// The account's Unity AI Gateway models, under each gateway's provider row as the Connectors page groups services: the
/// Databricks account's own gateway and the workspaces added under Models. Each model turns on or off with a switch;
/// only those turned on go to the account's `models.json`, so Pi, and with it the chat, summary, and image analysis model
/// pickers, knows only them.
private struct AgentModelSettingsView: View {
    let mcp: AgentMCPSettingsModel
    let subscriptions: [PiSubscriptionController]
    let onManage: () -> Void
    private let service = PiRuntimeService.shared
    /// Each provider's models by provider ID, as last listed.
    @State private var models: [String: [PiProviderConfiguration.DatabricksModel]] = [:]
    @State private var choices: [String: Bool] = [:]
    @State private var loadingProviderIDs: Set<String> = []
    @State private var errors: [String: String] = [:]

    /// Models on in a provider account's gateway, which keeps at least one.
    private func onCount(_ providerID: String) -> Int {
        (models[providerID] ?? []).count(where: { $0.isOn(shownChoices(providerID)) })
    }

    /// The switches as `models.json` applies them: an own gateway that lost the model kept on shows its default on.
    private func shownChoices(_ providerID: String) -> [String: Bool] {
        PiProviderConfiguration.effectiveChoices(choices, for: models[providerID] ?? [])
    }

    var body: some View {
        Form {
            AgentProviderSection(
                model: mcp, subscriptions: subscriptions, onManage: onManage,
                enabledCount: { provider in
                    models[provider.id].map { $0.count(where: { $0.isOn(shownChoices(provider.id)) }) }
                },
                modelsContent: modelRows,
                subscriptionEnabledCount: { controller in
                    controller.models.count { AgentModelSettings.isSubscriptionModelOn($0.model, choices: choices) }
                },
                subscriptionModelsContent: subscriptionModelRows
            )
            AccountProcessingSettingsView()
        }
        .formStyle(.grouped)
        .font(.dahliaBody)
        // The account's own workspace is found after the tab opens.
        .task(id: mcp.selectableProviders) {
            choices = AgentModelSettings.choices()
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

    private func subscriptionModelRows(_ controller: PiSubscriptionController) -> some View {
        ForEach(controller.models) { model in
            Toggle(model.displayName, isOn: Binding {
                AgentModelSettings.isSubscriptionModelOn(model.model, choices: choices)
            } set: { isOn in
                choices[model.model] = isOn
                AgentModelSettings.setModel(model.model, on: isOn)
                Task { await service.subscriptionModelChoicesDidChange() }
            })
            .toggleStyle(.dahliaSwitch)
            .foregroundStyle(AgentModelSettings.isSubscriptionModelOn(model.model, choices: choices) ? .primary : .secondary)
        }
    }

    @ViewBuilder
    private func modelRows(_ provider: AgentMCPProvider) -> some View {
        let providerModels = models[provider.id] ?? []
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
                    .toggleStyle(.dahliaSwitch)
                    // A chat needs a model, so a Databricks account keeps one on in its own gateway:
                    // its other models come from workspaces that can be removed.
                    .disabled(isOn && provider.isAccount && onCount(provider.id) == 1)
            } label: {
                HStack(spacing: 4) {
                    // A model turned off reads fainter.
                    Text(model.name).foregroundStyle(isOn ? .primary : .secondary)
                    AgentModelDetailsButton(model: model)
                }
            }
        }
    }

    /// Lists the gateway's models; the last list serves until `forceRefresh`.
    private func load(_ provider: AgentMCPProvider, forceRefresh: Bool) async {
        loadingProviderIDs.insert(provider.id)
        defer { loadingProviderIDs.remove(provider.id) }
        do {
            models[provider.id] = try await service.gatewayModels(provider: provider, forceRefresh: forceRefresh)
            errors[provider.id] = nil
        } catch is CancellationError {
            // Leaving the tab stops the listing.
        } catch {
            errors[provider.id] = message(error, provider: provider)
        }
    }

    private func message(_ error: any Error, provider: AgentMCPProvider) -> String {
        guard case .notLoggedIn = error as? PiRuntimeError else { return error.localizedDescription }
        // Both sign in again under Settings > Providers.
        return provider.isAccount ? L10n.mcpAccountSignInRequired : L10n.mcpProviderSignInRequired
    }

    private func on(_ model: PiProviderConfiguration.DatabricksModel, of provider: AgentMCPProvider) -> Binding<Bool> {
        Binding {
            model.isOn(shownChoices(provider.id))
        } set: { isOn in
            choices[model.reference] = isOn
            AgentModelSettings.setModel(model.reference, on: isOn)
            Task {
                do {
                    try await service.applyGatewayModelChoices()
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

/// A Databricks account can let chat use its workspace's Omnigent and list the sessions in the Chat sidebar.
private struct AgentOmnigentSection: View {
    @AppStorage private var isEnabled: Bool

    init() {
        _isEnabled = AppStorage(wrappedValue: false, OmnigentService.enabledKey(AppAccount.key))
    }

    var body: some View {
        Section {
            Toggle(L10n.omnigentEnabled, isOn: $isEnabled)
                .toggleStyle(.dahliaSwitch)
        } header: {
            Text(L10n.omnigent).font(.dahliaSectionHeader)
        } footer: {
            Text(L10n.omnigentEnabledHelp)
        }
    }
}
