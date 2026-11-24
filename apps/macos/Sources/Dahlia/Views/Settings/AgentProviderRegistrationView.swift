import SwiftUI

/// Adds a Pi subscription, Databricks workspace, or direct Google account through browser sign-in. Providers are one
/// list: a subscription row starts its sign-in when clicked, and a row that needs more before it (Databricks's
/// workspace URL, Google's disclosure) expands in place with its own sign-in button. The setup tour embeds the list
/// for one capability; it stays open after a sign-in and marks the providers already added.
struct AgentProviderRegistrationView: View {
    enum Kind: Hashable, Identifiable {
        case subscription(PiSubscription)
        case databricks
        case google

        var id: Self { self }

        var capabilities: [AgentProviderCapability] {
            switch self {
            case .subscription: [.models]
            case .databricks: [.models, .mcp, .calendar]
            case .google: [.calendar, .storage]
            }
        }

        /// Whether the row expands to ask for more before it can sign in.
        var needsDetails: Bool {
            if case .subscription = self { false } else { true }
        }

        @MainActor
        func canOpen(subscriptions: [PiSubscriptionController], isSigningIn: Bool) -> Bool {
            guard !isSigningIn else { return false }
            guard case let .subscription(subscription) = self else { return true }
            guard let controller = subscriptions.first(where: { $0.subscription == subscription }) else { return false }
            return !controller.isBusy && controller.accountStatus?.isAuthenticated != true
        }

        static func matching(_ capability: AgentProviderCapability?, subscriptions: [PiSubscription]) -> [Self] {
            (subscriptions.map(subscription) + [.google, .databricks]).filter { kind in
                capability.map { kind.capabilities.contains($0) } ?? true
            }
        }
    }

    let model: AgentMCPSettingsModel
    /// The Local Account's subscriptions; other accounts have none.
    let subscriptions: [PiSubscriptionController]
    let google: GoogleProviderAccountController
    let isEmbedded: Bool
    let onClose: () -> Void

    @State private var capability: AgentProviderCapability?
    @State private var workspaceSettings = WorkspaceAISettingsModel.shared
    @State private var expanded: Kind?
    @State private var hovered: Kind?
    @State private var workspaceURL = ""
    @State private var signingIn: Kind?
    @State private var signInTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @FocusState private var isWorkspaceURLFocused: Bool

    init(
        model: AgentMCPSettingsModel,
        subscriptions: [PiSubscriptionController],
        google: GoogleProviderAccountController,
        capability: AgentProviderCapability? = nil,
        isEmbedded: Bool = false,
        onClose: @escaping () -> Void
    ) {
        self.model = model
        self.subscriptions = subscriptions
        self.google = google
        self.isEmbedded = isEmbedded
        self.onClose = onClose
        _capability = State(initialValue: capability)
    }

    var body: some View {
        Group {
            if isEmbedded {
                content
            } else {
                ZStack {
                    Button(action: cancel) {
                        Color.black.opacity(0.16).ignoresSafeArea()
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .accessibilityHidden(true)

                    content
                        .padding(24)
                        .frame(width: 520)
                        .dahliaModalSurface()
                }
                .transition(.identity)
            }
        }
        .onChange(of: capability) { _, _ in
            if let expanded, !visibleKinds.contains(expanded) { self.expanded = nil }
        }
        .onChange(of: expanded) { _, newValue in
            errorMessage = nil
            isWorkspaceURLFocused = newValue == .databricks
        }
        .onDisappear { signInTask?.cancel() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !isEmbedded {
                Text(L10n.addProviderTitle)
                    .font(.dahliaTitle2)
                    .accessibilityAddTraits(.isHeader)

                HStack(spacing: 6) {
                    FilterChip(title: L10n.all, isSelected: capability == nil) { capability = nil }
                    ForEach(AgentProviderCapability.allCases, id: \.self) { choice in
                        FilterChip(title: choice.title, isSelected: capability == choice) { capability = choice }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(L10n.filter)
                .disabled(signInTask != nil)
            }

            VStack(spacing: 0) {
                ForEach(Array(visibleKinds.enumerated()), id: \.element) { index, choice in
                    if index > 0 { Divider() }
                    row(choice)
                }
            }
            .clipShape(.rect(cornerRadius: DahliaDesign.Card.regularCornerRadius))
            .dahliaCardSurface()

            if isEmbedded, !workspaceSettings.databricksConnections.isEmpty {
                Text(L10n.registeredProviderSignInAgainHint)
                    .font(.dahliaSecondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if signInTask != nil || !isEmbedded {
                HStack {
                    if signInTask != nil {
                        ProgressView().controlSize(.small)
                        Text(L10n.dahliaWaitingForBrowser).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(signInTask == nil ? L10n.cancel : L10n.cancelSignIn, action: cancelOrStop)
                        .buttonStyle(.dahlia())
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
    }

    private func row(_ choice: Kind) -> some View {
        let isAdded = isAdded(choice)
        let isEnabled = choice.canOpen(subscriptions: subscriptions, isSigningIn: signInTask != nil)
        return VStack(alignment: .leading, spacing: 0) {
            Button { open(choice) } label: {
                HStack(spacing: 12) {
                    image(for: choice)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 28, height: 28)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(for: choice))
                            .font(.dahliaHeadline)
                        Text(choice.capabilities.map(\.title).joined(separator: " · "))
                            .font(.dahliaSecondary)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    trailing(choice, isAdded: isAdded)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(.rect)
                .background(hovered == choice && isEnabled ? DahliaDesign.contentHighlightColor : .clear)
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .onHover { isHovering in
                if isHovering { hovered = choice } else if hovered == choice { hovered = nil }
            }

            if expanded == choice {
                details(choice)
                    .padding(.leading, 54)
                    .padding(.trailing, 14)
                    .padding(.bottom, 12)
                    .disabled(signInTask != nil)
            }
        }
    }

    @ViewBuilder
    private func trailing(_ choice: Kind, isAdded: Bool) -> some View {
        if isAdded {
            Label(choice == .databricks ? L10n.providerRegistered : L10n.codexSignedIn, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
        } else if signingIn == choice || subscriptions.contains(where: { choice == .subscription($0.subscription) && $0.isBusy }) {
            ProgressView().controlSize(.small)
        } else if choice.needsDetails {
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded == choice ? 90 : 0))
                .dahliaFixedSymbol()
        } else {
            Label(L10n.dahliaSignIn, systemImage: "arrow.up.forward")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.tint)
        }
    }

    @ViewBuilder
    private func details(_ choice: Kind) -> some View {
        switch choice {
        case .databricks:
            HStack(spacing: 8) {
                TextField(L10n.workspaceURL, text: $workspaceURL, prompt: Text(L10n.databricksWorkspaceURLPlaceholder))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.URL)
                    .focused($isWorkspaceURLFocused)
                    .onSubmit { signIn(.databricks) }
                signInButton(.databricks)
            }
        case .google:
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.googleProviderSignInDescription)
                    .font(.dahliaSecondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !google.isConfigured {
                    Text(L10n.googleAccountClientIDMissingMessage).font(.dahliaSecondary).foregroundStyle(.orange)
                }
                HStack {
                    Link(L10n.viewPrivacyPolicy, destination: GoogleOAuthDisclosure.privacyPolicyURL(for: AppSettings.shared.appLanguage.locale))
                        .font(.dahliaSecondary)
                    Spacer()
                    signInButton(.google)
                }
            }
        case .subscription:
            EmptyView()
        }
    }

    private func signInButton(_ choice: Kind) -> some View {
        Button(choice == .google ? L10n.googleProviderConnectBoth : L10n.dahliaSignIn) { signIn(choice) }
            .buttonStyle(.dahlia(.primary))
            .keyboardShortcut(isEmbedded ? nil : .defaultAction)
            .disabled(!canSignIn(choice))
    }

    private var visibleKinds: [Kind] {
        Kind.matching(capability, subscriptions: subscriptions.map(\.subscription))
    }

    private func open(_ choice: Kind) {
        if choice.needsDetails {
            withAnimation(.snappy(duration: 0.2)) { expanded = expanded == choice ? nil : choice }
        } else {
            expanded = nil
            signIn(choice)
        }
    }

    /// Databricks can be added more than once, so only the embedded list, which has no other place to show
    /// connections, marks it as added.
    private func isAdded(_ kind: Kind) -> Bool {
        switch kind {
        case let .subscription(subscription):
            subscriptions.first { $0.subscription == subscription }?.accountStatus?.isAuthenticated == true
        case .databricks:
            isEmbedded && !workspaceSettings.databricksConnections.isEmpty
        case .google:
            false
        }
    }

    private func canSignIn(_ kind: Kind) -> Bool {
        guard kind.canOpen(subscriptions: subscriptions, isSigningIn: signInTask != nil) else { return false }
        switch kind {
        case .google:
            return google.isConfigured && !google.isBusy
        case .databricks:
            return !workspaceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .subscription:
            return true
        }
    }

    private func image(for kind: Kind) -> Image {
        switch kind {
        case let .subscription(subscription): subscription.logo
        case .google: .googleLogo
        case .databricks: .databricksLogo
        }
    }

    private func title(for kind: Kind) -> String {
        switch kind {
        case let .subscription(subscription): subscription.displayName
        case .google: L10n.google
        case .databricks: L10n.databricks
        }
    }

    private func signIn(_ kind: Kind) {
        guard canSignIn(kind) else { return }
        errorMessage = nil
        signingIn = kind
        switch kind {
        case let .subscription(subscription):
            guard let controller = subscriptions.first(where: { $0.subscription == subscription }) else { return }
            signInTask = Task {
                await controller.signIn()
                if Task.isCancelled {
                    // Cancel has closed the modal already; a sign-in Pi saved still appears under Providers.
                } else if controller.accountStatus?.isAuthenticated == true {
                    onClose()
                } else {
                    errorMessage = controller.errorMessage
                }
                finishSignIn()
            }
        case .google:
            signInTask = Task {
                let signedIn = await google.signIn()
                if !Task.isCancelled {
                    if signedIn { onClose() } else { errorMessage = google.errorMessage }
                }
                finishSignIn()
            }
        case .databricks:
            signInTask = Task {
                do {
                    _ = try await model.addWorkspace(workspaceURL: workspaceURL)
                    expanded = nil
                    workspaceURL = ""
                    onClose()
                } catch is CancellationError {
                    // Closing the modal stops the browser sign-in.
                } catch {
                    errorMessage = error.localizedDescription
                }
                finishSignIn()
            }
        }
    }

    private func finishSignIn() {
        signInTask = nil
        signingIn = nil
    }

    /// Closing the modal also stops a pending browser sign-in, like the backdrop.
    private func cancel() {
        signInTask?.cancel()
        onClose()
    }

    /// The embedded list has nothing to close, so its button only stops the browser sign-in, which then finishes itself.
    private func cancelOrStop() {
        if isEmbedded {
            signInTask?.cancel()
        } else {
            cancel()
        }
    }
}

/// One capability filter: a capsule that the chosen filter fills with the accent tint.
private struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.dahliaSecondary.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 4)
                .dahliaChipSurface(isHovered: isHovered && !isSelected, tint: isSelected ? .accentColor : nil)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
