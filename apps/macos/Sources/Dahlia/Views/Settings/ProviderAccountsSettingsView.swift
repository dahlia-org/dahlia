import SwiftUI

/// The provider accounts the app's account uses, and what each offers: the Pi subscriptions, the Databricks
/// connections, workspaces added before every connection was a provider account, and Google. Pages that use a
/// capability (models, MCP, calendar) choose among these; signing in and out happens here.
struct ProviderAccountsSettingsView: View {
    @Environment(MainWindowNavigation.self) private var navigation
    @State private var workspaceSettings = WorkspaceAISettingsModel.shared
    @State private var mcp = AgentMCPSettingsModel()
    @State private var subscriptions = PiSubscription.allCases.map { PiSubscriptionController(subscription: $0) }
    @State private var databricks = DatabricksAccountController()
    private enum RenameTarget {
        case databricks(DatabricksConnection)
        case google(GoogleProviderAccountController)
    }

    @State private var googleAccounts = GoogleProviderAccountsModel.shared
    @State private var pendingRename: RenameTarget?
    @State private var pendingRemoval: AgentMCPProvider?
    @State private var proposedName = ""
    @State private var pendingGoogleSignOut: GoogleProviderAccountController?

    private var signedInSubscriptions: [PiSubscriptionController] {
        subscriptions.filter { $0.accountStatus?.isAuthenticated == true }
    }

    /// Workspaces added before every Databricks connection was a provider account; Pi still holds their sign-ins.
    private var earlierWorkspaces: [AgentMCPProvider] {
        mcp.settings.providers.filter { !$0.isAccount }
    }

    var body: some View {
        form
            .alert(
                L10n.renameProviderAccount,
                isPresented: Binding(get: { pendingRename != nil }, set: { if !$0 { pendingRename = nil } })
            ) {
                TextField(L10n.name, text: $proposedName)
                Button(L10n.save) {
                    guard let target = pendingRename else { return }
                    pendingRename = nil
                    let name = proposedName
                    switch target {
                    case let .databricks(connection):
                        Task { await workspaceSettings.renameDatabricksConnection(connection.id, to: name) }
                    case let .google(controller):
                        Task { await controller.rename(name) }
                    }
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
            .confirmationDialog(
                pendingGoogleSignOut?.displayName ?? L10n.google,
                isPresented: Binding(get: { pendingGoogleSignOut != nil }, set: { if !$0 { pendingGoogleSignOut = nil } }),
                titleVisibility: .visible
            ) {
                Button(L10n.signOut, role: .destructive) {
                    guard let controller = pendingGoogleSignOut else { return }
                    pendingGoogleSignOut = nil
                    Task { await controller.disconnect() }
                }
                Button(L10n.cancel, role: .cancel) { pendingGoogleSignOut = nil }
            } message: {
                Text(L10n.googleProviderSignOutDescription)
            }
            .task { await googleAccounts.activate() }
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
            .onChange(of: workspaceSettings.databricksConnections, initial: true) { _, _ in
                mcp.loadAccountProviders()
            }
            .onDisappear { navigation.dismissSettingsModal() }
    }

    private var form: some View {
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
                ForEach(googleAccounts.controllers) { googleRow($0) }
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
    }

    private var errors: [String] {
        subscriptions.compactMap(\.errorMessage)
            + [mcp.errorMessage, databricks.errorMessage, workspaceSettings.errorMessage, googleAccounts.errorMessage]
            .compactMap(\.self) + googleAccounts.controllers.compactMap(\.errorMessage)
    }

    // MARK: Rows

    private func subscriptionRow(_ controller: PiSubscriptionController) -> some View {
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
                    pendingRename = .databricks(connection)
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

    private func googleRow(_ google: GoogleProviderAccountController) -> some View {
        AgentProviderRow(title: google.displayName, icon: .googleLogo, uses: [L10n.calendar, L10n.agentProviderStorage]) {
            Text(google.isDisconnectPending ? L10n.googleProviderDisconnectPending : google.account?.email.nilIfBlank ?? L10n
                .providerAccountSignInToKeep)
                .foregroundStyle(.secondary)
            AgentProviderActions {
                Button(L10n.rename) {
                    proposedName = google.name ?? ""
                    pendingRename = .google(google)
                }
                .disabled(google.isDisconnectPending && google.account == nil)
                Button(L10n.signInAgain) { Task { _ = await google.signIn() } }
                Button(google.isDisconnectPending ? L10n.googleCalendarRetry : L10n.signOut) { pendingGoogleSignOut = google }
            }
            .disabled(google.isBusy)
        }
    }

    // MARK: Actions

    private func presentRegistration() {
        navigation.presentSettingsModal(
            AgentProviderRegistrationView(
                model: mcp,
                subscriptions: subscriptions,
                google: googleAccounts.registrationController(),
                onClose: navigation.dismissSettingsModal
            )
        )
    }

}
