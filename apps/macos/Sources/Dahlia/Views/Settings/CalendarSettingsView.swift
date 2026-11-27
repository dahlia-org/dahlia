import SwiftUI

/// Calendar providers and Mac-wide event filters. The setup tour shows only source setup.
struct CalendarSettingsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case sources
        case eventDisplay

        var id: Self { self }

        var label: String {
            switch self {
            case .sources: L10n.calendarSources
            case .eventDisplay: L10n.appearanceEventDisplay
            }
        }
    }

    @Environment(MainWindowNavigation.self) private var navigation
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var providers = CalendarProviderCollection.shared
    @ObservedObject private var macCalendarStore = MacCalendarStore.shared
    @State private var googleAccounts = GoogleProviderAccountsModel.shared
    @State private var expandedProviderIDs: Set<String> = []
    private let calendarSourceCoordinator = CalendarSourceCoordinator.shared
    private let showsOnlySourceSetup: Bool

    init(showsOnlySourceSetup: Bool = false) {
        self.showsOnlySourceSetup = showsOnlySourceSetup
    }

    var body: some View {
        @Bindable var navigation = navigation
        VStack(spacing: 0) {
            if !showsOnlySourceSetup {
                Form {
                    Section {
                        EmptyView()
                    } header: {
                        UnderlineTabBar(tabs: Tab.allCases, selection: $navigation.calendarTab, label: \.label, accessibilityLabel: L10n.calendar)
                    }
                }
                .formStyle(.grouped)
                .fixedSize(horizontal: false, vertical: true)
            }

            if !showsOnlySourceSetup, navigation.calendarTab == .eventDisplay {
                Form {
                    CalendarEventFilterSettingsView(settings: settings)
                }
                .formStyle(.grouped)
            } else {
                sourceSettings
            }
        }
        .task {
            await googleAccounts.activate()
            await providers.reloadConnections()
            await refreshEnabledSources()
        }
        .onChange(of: settings.enabledCalendarSources) { _, _ in
            Task { await refreshEnabledSources(force: true) }
        }
        .onAppear {
            if settings.isCalendarSourceEnabled(.macOS) { expandedProviderIDs.insert(CalendarSource.macOS.rawValue) }
            expandedProviderIDs.formUnion(providers.enabledIDs)
        }
        .font(.dahliaBody)
    }

    private var sourceSettings: some View {
        Form {
            Section {
                providerRow(
                    id: CalendarSource.macOS.rawValue, title: L10n.macOSCalendar,
                    icon: Image(systemName: "calendar"), isOn: calendarSourceBinding(for: .macOS)
                ) { macCalendarContent }
                ForEach(providers.connections) { connection in
                    if let store = providers.stores[connection.id] as? GoogleCalendarStore {
                        providerRow(
                            id: connection.id, title: connection.displayName,
                            icon: connection.provider.databricksConnectionID == nil ? CalendarSource.google.choiceCardImage : .databricksLogo,
                            isOn: providerBinding(connection.id)
                        ) {
                            if providers.enabledIDs.contains(connection.id) {
                                GoogleCalendarConnectionSettings(googleCalendarStore: store)
                            } else {
                                Text(L10n.calendarProviderTurnOnToConnect).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                // The setup tour cannot open Settings, so it adds a calendar provider in place.
                Button(showsOnlySourceSetup ? L10n.addProvider : L10n.manageProviders, action: manageProviders)
                    .buttonStyle(.dahlia())
                if let error = googleAccounts.errorMessage ?? providers.catalogError { calendarErrorMessage(error) }
            } header: {
                Text(L10n.calendarProviders).font(.dahliaSectionHeader)
            } footer: {
                Text(L10n.calendarSourcesDescription)
            }
        }
        .formStyle(.grouped)
    }

    /// One provider, folded like the model and MCP providers: its switch on the row, its connection and calendars inside.
    private func providerRow(
        id: String, title: String, icon: Image, isOn: Binding<Bool>, @ViewBuilder content: () -> some View
    ) -> some View {
        let content = content()
        return DisclosureGroup(isExpanded: expansion(of: id)) {
            content
        } label: {
            AgentProviderRow(title: title, icon: icon, uses: []) {
                Toggle(title, isOn: isOn)
                    .labelsHidden()
                    .toggleStyle(.dahliaSwitch)
            }
            .contentShape(.rect)
            .onTapGesture { expansion(of: id).wrappedValue.toggle() }
            .accessibilityAddTraits(.isButton)
        }
    }

    private func expansion(of id: String) -> Binding<Bool> {
        Binding {
            expandedProviderIDs.contains(id)
        } set: { expanded in
            if expanded { expandedProviderIDs.insert(id) } else { expandedProviderIDs.remove(id) }
        }
    }

    @ViewBuilder
    private var macCalendarContent: some View {
        macCalendarAccessRow
        if let message = macCalendarStore.lastErrorMessage {
            calendarErrorMessage(message)
        }
        if settings.isCalendarSourceEnabled(.macOS), macCalendarStore.isAuthorized {
            macCalendarSelection
        }
    }

    private func calendarErrorMessage(_ message: String) -> SettingsStatusMessage {
        SettingsStatusMessage(text: message, systemImage: "exclamationmark.triangle", tint: .orange)
    }

    private func providerBinding(_ id: String) -> Binding<Bool> {
        Binding {
            providers.enabledIDs.contains(id)
        } set: { enabled in
            providers.setEnabled(enabled, for: id)
            settings.setCalendarSource(.google, isEnabled: !providers.enabledIDs.isEmpty)
            if enabled { expandedProviderIDs.insert(id) }
        }
    }

    private var macCalendarSelection: some View {
        CalendarSourceSelectionView(
            sourceName: L10n.googleCalendarDisplayCalendars,
            calendars: macCalendarStore.availableCalendars,
            isLoading: macCalendarStore.isBusy,
            loadingMessage: L10n.macOSCalendarLoading,
            emptyMessage: L10n.macOSCalendarNoCalendars,
            selectionBinding: macCalendarSelectionBinding
        )
    }

    private var macCalendarAccessRow: some View {
        LabeledContent {
            macCalendarActionButton
        } label: {
            Text(macCalendarStore.isAuthorized ? L10n.macOSCalendarAccessGranted : L10n.macOSCalendarAccessNotGranted)
            Text(macCalendarSubtitle)
        }
    }

    @ViewBuilder
    private var macCalendarActionButton: some View {
        if macCalendarStore.state == .notDetermined {
            Button(L10n.macOSCalendarAllowAccess) {
                Task {
                    await macCalendarStore.requestAccess()
                }
            }
            .buttonStyle(.dahlia(.primary))
            .disabled(macCalendarStore.isBusy)
        } else {
            Button(L10n.googleCalendarRetry) {
                Task {
                    await macCalendarStore.refreshIfNeeded(force: true)
                }
            }
            .buttonStyle(.dahlia())
            .disabled(!macCalendarStore.isAuthorized || macCalendarStore.isBusy)
        }
    }

    private var macCalendarSubtitle: String {
        switch macCalendarStore.state {
        case .notDetermined:
            L10n.macOSCalendarConnectDescription
        case .accessDenied:
            L10n.macOSCalendarAccessDeniedMessage
        case .loading:
            L10n.macOSCalendarLoading
        case .needsCalendarSelection:
            L10n.calendarSelectionRequiredMessage
        case .loaded:
            L10n.macOSCalendarConnected
        case .failed:
            macCalendarStore.lastErrorMessage ?? L10n.macOSCalendarUnexpectedError
        }
    }

    private func calendarSourceBinding(for source: CalendarSource) -> Binding<Bool> {
        Binding {
            settings.isCalendarSourceEnabled(source)
        } set: { isEnabled in
            settings.setCalendarSource(source, isEnabled: isEnabled)
        }
    }

    private func macCalendarSelectionBinding(_ id: String) -> Binding<Bool> {
        Binding {
            macCalendarStore.selectedCalendarIDs.contains(id)
        } set: { isSelected in
            let wasSelected = macCalendarStore.selectedCalendarIDs.contains(id)
            guard isSelected != wasSelected else { return }
            macCalendarStore.toggleCalendarSelection(id: id)
        }
    }

    private func refreshEnabledSources(force: Bool = false) async {
        await calendarSourceCoordinator.refreshEnabledSources(settings.enabledCalendarSources, force: force)
    }

    private func manageProviders() {
        guard showsOnlySourceSetup else {
            navigation.openSettings(category: .providers)
            return
        }
        navigation.presentSettingsModal(
            AgentProviderRegistrationView(
                model: AgentMCPSettingsModel(),
                subscriptions: [],
                google: googleAccounts.registrationController(),
                capability: .calendar,
                onClose: navigation.dismissSettingsModal
            )
        )
    }
}

private struct GoogleCalendarConnectionSettings: View {
    @ObservedObject var googleCalendarStore: GoogleCalendarStore
    @State private var googleOAuthConsent = GoogleOAuthConsentState()

    var body: some View {
        Group {
            googleConnectionRow
            if let message = googleCalendarStore.lastErrorMessage { googleCalendarError(message) }
            if googleCalendarStore.isAuthorized { googleCalendarSelection }
        }
        .sheet(item: $googleOAuthConsent.pendingDisclosure, onDismiss: startGoogleOAuthIfConsented) { disclosure in
            GoogleOAuthConsentSheet(disclosure: disclosure) { googleOAuthConsent.grantConsent() }
        }
    }

    @ViewBuilder
    private func googleCalendarError(_ message: String) -> some View {
        calendarErrorMessage(message)
        // Whether re-granting fixes the error is the user's call; the connection page is where they can.
        if let connectionPageURL = googleCalendarStore.databricksConnectionPageURL {
            Button(L10n.googleCalendarOpenDatabricksConnectionPage) {
                NSWorkspace.shared.open(connectionPageURL)
            }
            .buttonStyle(.dahlia())
        }
    }

    private var googleCalendarSelection: some View {
        CalendarSourceSelectionView(
            sourceName: L10n.googleCalendarDisplayCalendars,
            calendars: googleCalendarStore.availableCalendars,
            isLoading: googleCalendarStore.isBusy,
            loadingMessage: L10n.googleCalendarLoading,
            emptyMessage: L10n.googleCalendarNoCalendars,
            selectionBinding: googleCalendarSelectionBinding
        )
    }

    private func startGoogleOAuthIfConsented() {
        guard googleOAuthConsent.consumeConsent() else { return }
        Task {
            await googleCalendarStore.signIn()
        }
    }

    private func calendarErrorMessage(_ message: String) -> SettingsStatusMessage {
        SettingsStatusMessage(
            text: message,
            systemImage: "exclamationmark.triangle",
            tint: .orange
        )
    }

    private var googleConnectionRow: some View {
        LabeledContent {
            googleActionButton
        } label: {
            Text(googleCalendarStore.account?.displayName ?? L10n.googleCalendarNotConnected)
            Text(googleAccountSubtitle)
        }
    }

    @ViewBuilder
    private var googleActionButton: some View {
        if !googleCalendarStore.isAuthorized {
            HStack {
                // The Databricks route restores on every launch until Disconnect opts out, even while it fails.
                if googleCalendarStore.restoresThroughDatabricksProxy {
                    googleDisconnectButton
                }
                Button(L10n.googleCalendarConnect) {
                    if googleCalendarStore.usesDatabricksProxy {
                        Task { await googleCalendarStore.signIn() }
                    } else {
                        googleOAuthConsent.request(.calendar)
                    }
                }
                .buttonStyle(.dahlia(.primary))
                .disabled(!googleCalendarStore.isConfigured || googleCalendarStore.isBusy)
            }
        } else {
            googleDisconnectButton
        }
    }

    private var googleDisconnectButton: some View {
        Button(L10n.googleCalendarDisconnect) {
            Task {
                await googleCalendarStore.disconnect()
            }
        }
        .buttonStyle(.dahlia())
        .disabled(!googleCalendarStore.isConfigured || googleCalendarStore.isBusy)
    }

    private var googleAccountSubtitle: String {
        if !googleCalendarStore.isConfigured {
            return L10n.googleCalendarClientIDMissingMessage
        }

        if googleCalendarStore.usesDatabricksProxy {
            return googleCalendarStore.isAuthorized
                ? L10n.googleCalendarDatabricksConnected
                : L10n.googleCalendarDatabricksConnectDescription
        }

        if let account = googleCalendarStore.account, googleCalendarStore.isAuthorized {
            return account.email.isEmpty ? L10n.googleCalendarConnected : account.email
        }

        if let account = googleCalendarStore.account {
            return account.email.isEmpty ? L10n.googleAccountConnectedWithoutCalendar : account.email
        }

        return L10n.googleCalendarConnectDescription
    }

    private func googleCalendarSelectionBinding(_ id: String) -> Binding<Bool> {
        Binding {
            googleCalendarStore.selectedCalendarIDs.contains(id)
        } set: { isSelected in
            let wasSelected = googleCalendarStore.selectedCalendarIDs.contains(id)
            guard isSelected != wasSelected else { return }
            googleCalendarStore.toggleCalendarSelection(id: id)
        }
    }

}

private struct CalendarSourceSelectionView: View {
    let sourceName: String
    let calendars: [CalendarListItem]
    let isLoading: Bool
    let loadingMessage: String
    let emptyMessage: String
    let selectionBinding: (String) -> Binding<Bool>

    var body: some View {
        VStack(alignment: .leading) {
            Text(sourceName)

            if isLoading, calendars.isEmpty {
                ProgressView(loadingMessage)
            } else if calendars.isEmpty {
                Text(emptyMessage)
                    .foregroundStyle(DahliaDesign.secondaryTextColor)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading) {
                        ForEach(calendars) { calendar in
                            Toggle(isOn: selectionBinding(calendar.id)) {
                                Label {
                                    Text(calendar.title)
                                } icon: {
                                    Circle()
                                        .fill(calendar.colorHex.map(Color.init(hex:)) ?? Color.accentColor)
                                        .frame(width: 10, height: 10)
                                        .accessibilityHidden(true)
                                }
                            }
                            .toggleStyle(.dahliaCheckbox)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 160)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension CalendarSource {
    var choiceCardImage: Image {
        guard self == .google,
              let url = Bundle.appModule.url(forResource: "GoogleCalendar", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            return Image(systemName: "calendar")
        }

        image.isTemplate = false
        return Image(nsImage: image)
    }
}
