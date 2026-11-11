import SwiftUI

/// The calendar sources of the open account, or of the account the setup tour is setting up. Settings that apply to
/// the whole app are in `AppearanceSettingsView` and `MeetingLinkSettingsView`.
struct CalendarSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var googleCalendarStore = GoogleCalendarStore.shared
    @ObservedObject private var macCalendarStore = MacCalendarStore.shared
    @State private var workspaceSettings = WorkspaceAISettingsModel.shared
    @State private var accountController = DahliaCloudAccountController.shared
    private let calendarSourceCoordinator = CalendarSourceCoordinator.shared
    private let showsOnlySourceSetup: Bool
    @State private var googleOAuthConsent = GoogleOAuthConsentState()

    init(showsOnlySourceSetup: Bool = false) {
        self.showsOnlySourceSetup = showsOnlySourceSetup
    }

    var body: some View {
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
                    LabeledContent(L10n.appliesToAccount, value: accountName)
                    ForEach([CalendarSource.macOS, .google]) { source in
                        Toggle(isOn: calendarSourceBinding(for: source)) {
                            Text(source.displayName)
                            Text(calendarSourceDescription(for: source))
                        }
                        .toggleStyle(.switch)
                    }
                } header: {
                    Text(L10n.calendarSources)
                        .font(.dahliaSectionHeader)
                } footer: {
                    Text(L10n.calendarSourcesDescription)
                }
            }

            if settings.isCalendarSourceEnabled(.macOS) {
                macCalendarSettings
            }

            if settings.isCalendarSourceEnabled(.google) {
                googleCalendarSettings
            }

            if showsCalendarSelection {
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
        .sheet(item: $googleOAuthConsent.pendingDisclosure, onDismiss: startGoogleOAuthIfConsented) { disclosure in
            GoogleOAuthConsentSheet(disclosure: disclosure) {
                googleOAuthConsent.grantConsent()
            }
        }
        .formStyle(.grouped)
        .font(.dahliaBody)
    }

    private var showsCalendarSelection: Bool {
        settings.isCalendarSourceEnabled(.macOS) && macCalendarStore.isAuthorized
            || settings.isCalendarSourceEnabled(.google) && googleCalendarStore.isAuthorized
    }

    private var accountName: String {
        switch settings.calendarAccount {
        case .local:
            L10n.localAccount
        case let .databricks(connectionID):
            workspaceSettings.databricksConnections.first { $0.id == connectionID }?.accountLabel ?? L10n.databricks
        case let .dahlia(connectionID):
            accountController.connections.first { $0.id == connectionID }?.displayName ?? L10n.dahliaAccount
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
                calendarErrorMessage(message)
                // Whether re-granting fixes the error is the user's call; the connection page is where they can.
                if let connectionPageURL = googleCalendarStore.databricksConnectionPageURL {
                    Button(L10n.googleCalendarOpenDatabricksConnectionPage) {
                        NSWorkspace.shared.open(connectionPageURL)
                    }
                    .buttonStyle(.dahlia())
                }
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
