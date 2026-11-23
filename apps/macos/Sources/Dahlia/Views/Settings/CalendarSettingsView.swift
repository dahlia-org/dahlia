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
    @ObservedObject private var googleCalendarStore = GoogleCalendarStore.shared
    @ObservedObject private var macCalendarStore = MacCalendarStore.shared
    @State private var workspaceSettings = WorkspaceAISettingsModel.shared
    @State private var expandedProviderIDs: Set<String> = []
    /// Read again when the choice changes, so the rows follow it.
    @State private var googleProvider = GoogleCalendarProvider.current()
    private let calendarSourceCoordinator = CalendarSourceCoordinator.shared
    private let showsOnlySourceSetup: Bool
    @State private var googleOAuthConsent = GoogleOAuthConsentState()

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
            if showsOnlySourceSetup {
                settings.enabledCalendarSources = [Self.exclusiveSetupSource(from: settings.enabledCalendarSources)]
            }
            await refreshEnabledSources()
        }
        .onChange(of: settings.enabledCalendarSources) { _, _ in
            Task {
                await refreshEnabledSources(force: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: GoogleCalendarProvider.didChange)) { _ in
            googleProvider = GoogleCalendarProvider.current()
        }
        .onChange(of: workspaceSettings.databricksConnections, initial: true) { _, _ in
            googleProvider = GoogleCalendarProvider.current()
        }
        .onAppear {
            // The providers in use open, so their connection and calendars show without a click.
            if settings.isCalendarSourceEnabled(.macOS) { expandedProviderIDs.insert(CalendarSource.macOS.rawValue) }
            if settings.isCalendarSourceEnabled(.google) {
                expandedProviderIDs.insert(googleProvider.databricksConnectionID?.uuidString ?? "google")
            }
        }
        .sheet(item: $googleOAuthConsent.pendingDisclosure, onDismiss: startGoogleOAuthIfConsented) { disclosure in
            GoogleOAuthConsentSheet(disclosure: disclosure) {
                googleOAuthConsent.grantConsent()
            }
        }
        .font(.dahliaBody)
    }

    private var sourceSettings: some View {
        Form {
            if showsOnlySourceSetup {
                Section {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach([CalendarSource.macOS, .google]) { source in
                            SetupChoiceCard(
                                image: source.choiceCardImage,
                                title: source.displayName,
                                description: source.choiceCardDescription,
                                isSelected: settings.enabledCalendarSources == [source]
                            ) {
                                settings.enabledCalendarSources = [source]
                            }
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                }
            } else {
                Section {
                    providerRow(
                        id: CalendarSource.macOS.rawValue,
                        title: L10n.macOSCalendar,
                        icon: Image(systemName: "calendar"),
                        isOn: calendarSourceBinding(for: .macOS)
                    ) {
                        macCalendarContent
                    }
                    providerRow(
                        id: "google",
                        title: L10n.google,
                        icon: CalendarSource.google.choiceCardImage,
                        isOn: googleProviderBinding(.google)
                    ) {
                        googleCalendarContent(for: .google)
                    }
                    // shortcut: the account uses only its oldest Databricks connection; list each once each has its own route.
                    if let connection = workspaceSettings.databricksConnections.first {
                        let provider = GoogleCalendarProvider.databricks(connectionID: connection.id)
                        providerRow(
                            id: connection.id.uuidString,
                            title: connection.displayName,
                            icon: .databricksLogo,
                            isOn: googleProviderBinding(provider)
                        ) {
                            googleCalendarContent(for: provider)
                        }
                    }
                } header: {
                    Text(L10n.calendarProviders)
                        .font(.dahliaSectionHeader)
                } footer: {
                    Text(L10n.calendarSourcesDescription)
                }
            }

            if showsOnlySourceSetup {
                if settings.isCalendarSourceEnabled(.macOS) {
                    macCalendarSettings
                }
                if settings.isCalendarSourceEnabled(.google) {
                    googleCalendarSettings
                }
                if showsCalendarSelection {
                    calendarSelectionSection
                }
            }
        }
        .formStyle(.grouped)
    }

    private var showsCalendarSelection: Bool {
        settings.isCalendarSourceEnabled(.macOS) && macCalendarStore.isAuthorized
            || settings.isCalendarSourceEnabled(.google) && googleCalendarStore.isAuthorized
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
                    .toggleStyle(.switch)
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

    /// Only the provider that reads Google Calendar now can connect; the other asks to be turned on first.
    @ViewBuilder
    private func googleCalendarContent(for provider: GoogleCalendarProvider) -> some View {
        if settings.isCalendarSourceEnabled(.google), googleProvider == provider {
            googleConnectionRow
            if let message = googleCalendarStore.lastErrorMessage {
                googleCalendarError(message)
            }
            if googleCalendarStore.isAuthorized {
                googleCalendarSelection
            }
        } else {
            Text(L10n.calendarProviderTurnOnToConnect)
                .foregroundStyle(DahliaDesign.secondaryTextColor)
        }
    }

    /// Google and a Databricks connection read the same calendars, so turning one on turns the other off.
    private func googleProviderBinding(_ provider: GoogleCalendarProvider) -> Binding<Bool> {
        Binding {
            settings.isCalendarSourceEnabled(.google) && googleProvider == provider
        } set: { isOn in
            if isOn {
                if googleProvider != provider {
                    GoogleCalendarProvider.save(provider)
                    googleProvider = provider
                }
                settings.setCalendarSource(.google, isEnabled: true)
                expandedProviderIDs.insert(provider.databricksConnectionID?.uuidString ?? "google")
            } else if googleProvider == provider {
                settings.setCalendarSource(.google, isEnabled: false)
            }
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

    /// The setup tour's calendars, below its source choice.
    private var calendarSelectionSection: some View {
        Section {
            if settings.isCalendarSourceEnabled(.macOS), macCalendarStore.isAuthorized {
                CalendarSourceSelectionView(
                    sourceName: L10n.macOSCalendar,
                    calendars: macCalendarStore.availableCalendars,
                    isLoading: macCalendarStore.isBusy,
                    loadingMessage: L10n.macOSCalendarLoading,
                    emptyMessage: L10n.macOSCalendarNoCalendars,
                    selectionBinding: macCalendarSelectionBinding
                )
            }
            if settings.isCalendarSourceEnabled(.google), googleCalendarStore.isAuthorized {
                CalendarSourceSelectionView(
                    sourceName: L10n.googleCalendar,
                    calendars: googleCalendarStore.availableCalendars,
                    isLoading: googleCalendarStore.isBusy,
                    loadingMessage: L10n.googleCalendarLoading,
                    emptyMessage: L10n.googleCalendarNoCalendars,
                    selectionBinding: googleCalendarSelectionBinding
                )
            }
        } header: {
            Text(L10n.googleCalendarDisplayCalendars)
                .font(.dahliaSectionHeader)
        } footer: {
            Text(L10n.googleCalendarDisplayCalendarsDescription)
        }
    }

    static func exclusiveSetupSource(from sources: Set<CalendarSource>) -> CalendarSource {
        sources.count == 1 ? sources.first ?? .google : .google
    }

    private func startGoogleOAuthIfConsented() {
        guard googleOAuthConsent.consumeConsent() else { return }
        Task {
            await googleCalendarStore.signIn()
        }
    }

    private var googleCalendarSettings: some View {
        Section {
            googleConnectionRow

            if let message = googleCalendarStore.lastErrorMessage {
                googleCalendarError(message)
            }
        } header: {
            Text(L10n.googleCalendar)
                .font(.dahliaSectionHeader)
        } footer: {
            if !showsOnlySourceSetup {
                Text(L10n.googleCalendarSettingsDescription)
            }
        }
    }

    private var macCalendarSettings: some View {
        Section {
            macCalendarAccessRow

            if let message = macCalendarStore.lastErrorMessage {
                calendarErrorMessage(message)
            }
        } header: {
            Text(L10n.macOSCalendar)
                .font(.dahliaSectionHeader)
        } footer: {
            if !showsOnlySourceSetup {
                Text(L10n.macOSCalendarSettingsDescription)
            }
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

    private func calendarSourceDescription(for source: CalendarSource) -> String {
        switch source {
        case .google:
            L10n.googleCalendarSourceDescription
        case .macOS:
            L10n.macOSCalendarSourceDescription
        }
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
                            .toggleStyle(.checkbox)
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
