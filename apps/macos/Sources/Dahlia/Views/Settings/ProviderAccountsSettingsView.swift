import SwiftUI

/// The provider accounts the app's account uses, and what each offers: the Pi subscriptions, the Databricks
/// connections, workspaces added before every connection was a provider account, and Google. Pages that use a
/// capability (models, MCP, calendar) choose among these; signing in and out happens here.
struct ProviderAccountsSettingsView: View {
    @Environment(MainWindowNavigation.self) private var navigation
    @State private var workspaceSettings = WorkspaceAISettingsModel.shared
    @ObservedObject private var googleCalendarStore = GoogleCalendarStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var mcp = AgentMCPSettingsModel(account: .local)
    @State private var subscriptions = PiSubscription.allCases.map { CodexAccountController(subscription: $0) }
    @State private var databricks = DatabricksAccountController()
    @State private var pendingRename: DatabricksConnection?
    @State private var pendingRemoval: AgentMCPProvider?
    @State private var proposedName = ""
    @State private var googleOAuthConsent = GoogleOAuthConsentState()
    @State private var googleProvider = GoogleCalendarProvider.current(account: .local)

    private var signedInSubscriptions: [CodexAccountController] {
        subscriptions.filter { $0.accountStatus?.isAuthenticated == true }
    }

    /// Workspaces added before every Databricks connection was a provider account; Pi still holds their sign-ins.
    private var earlierWorkspaces: [AgentMCPProvider] {
        mcp.settings.providers.filter { !$0.isAccount }
    }

    var body: some View {
        Form {
            Section {
                ForEach(signedInSubscriptions, id: \.subscription) { controller in
                    subscriptionRow(controller)
                }
                ForEach(workspaceSettings.databricksConnections) { connection in
                    databricksRow(connection)
                }
                ForEach(earlierWorkspaces) { provider in
                    earlierWorkspaceRow(provider)
                }
                googleRow
                ForEach(errors, id: \.self) { message in
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } header: {
                AgentSectionHeader(title: L10n.providerAccounts) {
                    Button(L10n.addProvider, systemImage: "plus", action: presentRegistration)
                        .disabled(mcp.isBusy || databricks.isBusy)
                }
            } footer: {
                Text(L10n.providerAccountsDescription)
            }
        }
        .formStyle(.grouped)
        .font(.dahliaBody)
        .alert(
            L10n.renameProviderAccount,
            isPresented: Binding(get: { pendingRename != nil }, set: { if !$0 { pendingRename = nil } })
        ) {
            TextField(L10n.name, text: $proposedName)
            Button(L10n.save) {
                guard let connection = pendingRename else { return }
                pendingRename = nil
                let name = proposedName
                Task { await workspaceSettings.renameDatabricksConnection(connection.id, to: name) }
            }
            Button(L10n.cancel, role: .cancel) { pendingRename = nil }
        } message: {
            Text(L10n.renameProviderAccountDescription)
        }
        .confirmationDialog(
            pendingRemoval.map { L10n.mcpRemoveWorkspace($0.host) } ?? "",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button(L10n.delete, role: .destructive) {
                guard let provider = pendingRemoval else { return }
                pendingRemoval = nil
                Task { await mcp.remove(provider) }
            }
            Button(L10n.cancel, role: .cancel) { pendingRemoval = nil }
        } message: {
            Text(L10n.mcpRemoveWorkspaceDescription)
        }
        .sheet(item: $googleOAuthConsent.pendingDisclosure, onDismiss: connectGoogleIfConsented) { disclosure in
            GoogleOAuthConsentSheet(disclosure: disclosure) {
                googleOAuthConsent.grantConsent()
            }
        }
        .task {
            mcp.loadAccountProviders()
            for controller in subscriptions {
                await controller.activate()
            }
        }
        // A sign-in made elsewhere (the add modal or the setup tour) updates the subscriptions too.
        .onReceive(NotificationCenter.default.publisher(for: PiRuntimeService.modelsDidChange).receive(on: RunLoop.main)) { _ in
            Task {
                for controller in subscriptions where !controller.isBusy {
                    await controller.activate()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: GoogleCalendarProvider.didChange)) { _ in
            googleProvider = GoogleCalendarProvider.current(account: .local)
        }
        .onChange(of: workspaceSettings.databricksConnections, initial: true) { _, _ in
            googleProvider = GoogleCalendarProvider.current(account: .local)
            mcp.loadAccountProviders()
        }
        .onDisappear { navigation.dismissSettingsModal() }
    }

    private var errors: [String] {
        subscriptions.compactMap(\.errorMessage)
            + [mcp.errorMessage, databricks.errorMessage, workspaceSettings.errorMessage].compactMap(\.self)
    }

    // MARK: Rows

    private func subscriptionRow(_ controller: CodexAccountController) -> some View {
        AgentProviderRow(title: controller.subscription.displayName, icon: controller.subscription.logo, uses: [L10n.agentProviderModels]) {
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

    private func databricksRow(_ connection: DatabricksConnection) -> some View {
        AgentProviderRow(
            title: connection.displayName,
            icon: .databricksLogo,
            uses: [L10n.agentProviderModels, L10n.mcp, L10n.calendar]
        ) {
            Text(connection.hostName).foregroundStyle(.secondary)
            AgentProviderActions {
                Button(L10n.rename) {
                    proposedName = connection.name ?? ""
                    pendingRename = connection
                }
                Button(L10n.signInAgain) {
                    Task { _ = await databricks.signIn(workspaceURL: connection.host) }
                }
                Button(L10n.signOut) { workspaceSettings.requestDatabricksSignOut(connectionID: connection.id) }
            }
            .disabled(databricks.isBusy)
        }
    }

    /// Signing in again makes it a provider account, which keeps its host, servers, and models.
    private func earlierWorkspaceRow(_ provider: AgentMCPProvider) -> some View {
        AgentProviderRow(title: L10n.unityGatewayHost(provider.host), icon: .databricksLogo, uses: [L10n.agentProviderModels, L10n.mcp]) {
            Text(L10n.providerAccountSignInToKeep).foregroundStyle(.secondary)
            AgentProviderActions {
                Button(L10n.signInAgain) {
                    Task { _ = try? await mcp.addWorkspace(workspaceURL: provider.workspaceURL.absoluteString) }
                }
                Button(L10n.delete, role: .destructive) { pendingRemoval = provider }
            }
            .disabled(mcp.isBusy)
        }
    }

    /// Google reads the calendar and the Drive backups, from Google itself or through a Databricks connection.
    private var googleRow: some View {
        AgentProviderRow(title: L10n.google, icon: CalendarSource.google.choiceCardImage, uses: [L10n.calendar, L10n.googleDrive]) {
            if googleProvider == .google, googleCalendarStore.isAuthorized {
                Text(googleCalendarStore.account?.email.nilIfBlank ?? L10n.codexSignedIn).foregroundStyle(.secondary)
                AgentProviderActions {
                    Button(L10n.googleCalendarDisconnect) { Task { await googleCalendarStore.disconnect() } }
                }
                .disabled(googleCalendarStore.isBusy)
            } else {
                if case let .databricks(connectionID) = googleProvider,
                   let connection = workspaceSettings.databricksConnections.first(where: { $0.id == connectionID }) {
                    Text(L10n.googleReadThrough(connection.displayName)).foregroundStyle(.secondary)
                }
                Button(L10n.googleCalendarConnect) { googleOAuthConsent.request(.calendar) }
                    .disabled(!googleCalendarStore.isConfigured || googleCalendarStore.isBusy)
            }
        }
    }

    // MARK: Actions

    private func presentRegistration() {
        navigation.presentSettingsModal(
            AgentProviderRegistrationView(model: mcp, subscriptions: subscriptions, onClose: navigation.dismissSettingsModal)
        )
    }

    /// Connecting Google makes it the provider Google Calendar comes from, as turning it on in Calendar does.
    private func connectGoogleIfConsented() {
        guard googleOAuthConsent.consumeConsent() else { return }
        if googleProvider != .google {
            GoogleCalendarProvider.save(.google)
            googleProvider = .google
        }
        settings.setCalendarSource(.google, isEnabled: true)
        Task { await googleCalendarStore.signIn() }
    }
}
