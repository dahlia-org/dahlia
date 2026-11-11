import SwiftUI

/// The account's MCP catalog, grouped by provider.
struct AgentMCPSettingsView: View {
    let model: AgentMCPSettingsModel
    let onAdd: (AgentMCPProvider) -> Void
    @State private var collapsedProviderIDs: Set<String> = []
    @State private var query = ""
    @State private var serviceSignIn: (service: String, task: Task<Void, Never>)?
    /// Each provider's listing in progress, cancelled when the tab goes away.
    @State private var listings: [String: Task<Void, Never>] = [:]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField(L10n.search, text: $query, prompt: Text(L10n.mcpSearchPrompt))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(L10n.search)
                    Text(L10n.mcpSettingsDescription)
                        .font(.dahliaSecondary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(model.selectableProviders) { provider in
                    DisclosureGroup(isExpanded: expansion(of: provider)) {
                        services(of: provider)
                            .padding(.top, 12)
                    } label: {
                        HStack(spacing: 8) {
                            Image.databricksLogo.resizable().scaledToFit().frame(width: 16, height: 16)
                                .accessibilityHidden(true)
                            Text(L10n.unityGatewayHost(provider.host)).font(.dahliaHeadline)
                            Spacer()
                            Text(L10n.agentEnabledCount(model.servers(of: provider).count))
                                .font(.dahliaSecondary)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(.rect)
                        .onTapGesture { expansion(of: provider).wrappedValue.toggle() }
                        .accessibilityAddTraits(.isButton)
                    }
                }
                if model.selectableProviders.isEmpty {
                    Text(L10n.mcpNoProviders).foregroundStyle(.secondary)
                }
                if let errorMessage = model.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: 700)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .font(.dahliaBody)
        // The account's own workspace is found after the tab opens.
        .task(id: model.selectableProviders) {
            model.selectableProviders.forEach(list)
        }
        .onChange(of: model.settings.servers) { model.selectableProviders.forEach(list) }
        .onDisappear {
            serviceSignIn?.task.cancel()
            listings.values.forEach { $0.cancel() }
        }
    }

    @ViewBuilder
    private func services(of provider: AgentMCPProvider) -> some View {
        let services = model.listedServices(of: provider).sorted { lhs, rhs in
            if lhs.hasPrefix("system.ai.") != rhs.hasPrefix("system.ai.") { return lhs.hasPrefix("system.ai.") }
            return lhs < rhs
        }
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
        let filtered = services.filter { matchesQuery($0, comment: model.comment(for: $0, of: provider)) }
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(filtered, id: \.self) { service in
                serviceCard(service, of: provider)
            }
            Button { onAdd(provider) } label: {
                VStack(alignment: .leading, spacing: 12) {
                    Label(L10n.mcpAddService, systemImage: "plus").font(.dahliaHeadline)
                    Text(L10n.mcpServiceNameHelp).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .contentShape(.rect)
            }
            .buttonStyle(.dahlia())
        }
    }

    private func serviceCard(_ service: String, of provider: AgentMCPProvider) -> some View {
        let server = model.servers(of: provider).first { $0.service == service }
        let signInState = model.signInState(for: service, of: provider)
        return AgentMCPServiceCard(
            name: AgentMCPServer.displayName(for: service),
            comment: model.comment(for: service, of: provider) ?? service,
            icon: logo(for: service), isEnabled: enabled(service, of: provider)
        ) {
            if server == nil || !AgentMCPService.requiresUserSignIn(service) {
                EmptyView()
            } else if serviceSignIn?.service == serviceKey(service, of: provider) {
                ProgressView().controlSize(.small)
                Button(L10n.cancel, systemImage: "xmark") { serviceSignIn?.task.cancel() }
                    .labelStyle(.iconOnly)
                    .help(L10n.cancel)
                    .buttonStyle(AgentMCPIconButtonStyle())
            } else if signInState == .signedIn {
                Image(systemName: "checkmark")
                    .font(.dahliaSecondary)
                    .foregroundStyle(.green)
                    .frame(width: 24, height: 24)
                    .background(.green.opacity(0.08), in: .circle)
                    .overlay { Circle().strokeBorder(.green.opacity(0.18)) }
                    .accessibilityLabel(L10n.mcpServiceSignedIn)
                    .help(L10n.mcpServiceSignedIn)
            } else {
                Button(signInHelp(signInState), systemImage: "arrow.right.to.line") {
                    signIn(to: service, of: provider)
                }
                .labelStyle(.iconOnly)
                .help(signInHelp(signInState))
                .buttonStyle(AgentMCPIconButtonStyle())
                .disabled(serviceSignIn != nil || model.isBusy || model.listingProviderIDs.contains(provider.id))
            }
        }
        .help(server.map { L10n.mcpServiceWithServerName(service, $0.name) } ?? service)
    }

    private var columns: [GridItem] {
        [GridItem(.flexible(), alignment: .top), GridItem(.flexible(), alignment: .top)]
    }

    private func matchesQuery(_ service: String, comment: String?) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || service.localizedCaseInsensitiveContains(query)
            || AgentMCPServer.displayName(for: service).localizedCaseInsensitiveContains(query)
            || comment?.localizedCaseInsensitiveContains(query) == true
    }

    /// The service's brand logo by keyword; services with no brand of their own show a symbol.
    private func logo(for service: String) -> Image {
        let name = service.lowercased()
        let logos = [
            ("slack", "IntegrationSlack"), ("gmail", "IntegrationGmail"), ("drive", "IntegrationGoogleDrive"),
            ("github", "IntegrationGitHub"), ("atlassian", "IntegrationAtlassian"), ("jira", "IntegrationAtlassian"),
            ("confluence", "IntegrationAtlassian"), ("calendar", "IntegrationGoogleCalendar"),
            ("microsoft", "IntegrationMicrosoft365"), ("genie", "IntegrationGenie"), ("sql", "IntegrationDBSQL"),
        ]
        if let logo = logos.first(where: { name.contains($0.0) }), let image = Bundle.appModule.image(forResource: logo.1) {
            // The GitHub mark is black, so it takes the text color to show in dark mode.
            return Image(nsImage: image).renderingMode(logo.1 == "IntegrationGitHub" ? .template : .original)
        }
        if name.contains("search") { return Image(systemName: "magnifyingglass") }
        if name.contains("sandbox") { return Image(systemName: "apple.terminal") }
        return Image(systemName: "puzzlepiece.extension")
    }

    /// Lists open until closed, so the switches show without a click.
    private func expansion(of provider: AgentMCPProvider) -> Binding<Bool> {
        Binding {
            !collapsedProviderIDs.contains(provider.id)
        } set: { isExpanded in
            if isExpanded { collapsedProviderIDs.remove(provider.id) } else { collapsedProviderIDs.insert(provider.id) }
        }
    }

    /// One listing per provider at a time; a listing already running serves this request too.
    private func list(_ provider: AgentMCPProvider) {
        guard listings[provider.id] == nil else { return }
        listings[provider.id] = Task {
            let servers = model.servers(of: provider)
            await model.refreshServices(of: provider)
            listings[provider.id] = nil
            if !Task.isCancelled, servers != model.servers(of: provider) { list(provider) }
        }
    }

    private func enabled(_ service: String, of provider: AgentMCPProvider) -> Binding<Bool> {
        Binding {
            model.servers(of: provider).contains { $0.service == service }
        } set: { isOn in
            do {
                try model.setService(service, enabled: isOn, of: provider)
                model.errorMessage = nil
                if !isOn, serviceSignIn?.service == serviceKey(service, of: provider) { serviceSignIn?.task.cancel() }
                if isOn { list(provider) }
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

    private func signInHelp(_ state: AgentMCPService.SignInState) -> String {
        switch state {
        case .signedIn: L10n.mcpServiceSignedIn
        case .signInRequired: L10n.mcpServiceSignInRequired
        case .unknown: L10n.mcpServiceSignInUnknown
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
