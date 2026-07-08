import SwiftUI

struct CalendarSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var googleCalendarStore = GoogleCalendarStore.shared
    @ObservedObject private var macCalendarStore = MacCalendarStore.shared

    var body: some View {
        Form {
            Section {
                ForEach(CalendarSource.allCases) { source in
                    Toggle(isOn: calendarSourceBinding(for: source)) {
                        Text(source.displayName)
                        Text(calendarSourceDescription(for: source))
                    }
                    .toggleStyle(.switch)
                }
            } header: {
                Text(L10n.calendarSources)
            } footer: {
                Text(L10n.calendarSourcesDescription)
            }

            if settings.isCalendarSourceEnabled(.google) {
                googleCalendarSettings
            }

            if settings.isCalendarSourceEnabled(.macOS) {
                macCalendarSettings
            }
        }
        .task {
            await refreshEnabledSources()
        }
        .onChange(of: settings.enabledCalendarSourcesJSON) { _, _ in
            Task {
                await refreshEnabledSources(force: true)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var googleCalendarSettings: some View {
        Section {
            googleConnectionRow

            if let message = googleCalendarStore.lastErrorMessage {
                calendarErrorMessage(message)
            }
        } header: {
            Text(L10n.googleCalendar)
        } footer: {
            Text(L10n.googleCalendarSettingsDescription)
        }

        if googleCalendarStore.isAuthorized {
            Section {
                if googleCalendarStore.isBusy, googleCalendarStore.availableCalendars.isEmpty {
                    ProgressView(L10n.googleCalendarLoading)
                } else if googleCalendarStore.availableCalendars.isEmpty {
                    Text(L10n.googleCalendarNoCalendars)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(googleCalendarStore.availableCalendars) { calendar in
                        CalendarSelectionToggle(
                            calendar: calendar,
                            isSelected: googleCalendarSelectionBinding(for: calendar.id)
                        )
                    }
                }
            } header: {
                Text(L10n.googleCalendarDisplayCalendars)
            } footer: {
                Text(L10n.googleCalendarDisplayCalendarsDescription)
            }
        }
    }

    @ViewBuilder
    private var macCalendarSettings: some View {
        Section {
            macCalendarAccessRow

            if let message = macCalendarStore.lastErrorMessage {
                calendarErrorMessage(message)
            }
        } header: {
            Text(L10n.macOSCalendar)
        } footer: {
            Text(L10n.macOSCalendarSettingsDescription)
        }

        if macCalendarStore.isAuthorized {
            Section {
                if macCalendarStore.isBusy, macCalendarStore.availableCalendars.isEmpty {
                    ProgressView(L10n.macOSCalendarLoading)
                } else if macCalendarStore.availableCalendars.isEmpty {
                    Text(L10n.macOSCalendarNoCalendars)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(macCalendarStore.availableCalendars) { calendar in
                        CalendarSelectionToggle(
                            calendar: calendar,
                            isSelected: macCalendarSelectionBinding(for: calendar.id)
                        )
                    }
                }
            } header: {
                Text(L10n.googleCalendarDisplayCalendars)
            } footer: {
                Text(L10n.macOSCalendarDisplayCalendarsDescription)
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
            Button(L10n.googleCalendarConnect) {
                Task {
                    await googleCalendarStore.signIn()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!googleCalendarStore.isConfigured || googleCalendarStore.isBusy)
        } else {
            Button(L10n.googleCalendarDisconnect) {
                Task {
                    await googleCalendarStore.disconnect()
                }
            }
            .buttonStyle(.bordered)
            .disabled(!googleCalendarStore.isConfigured || googleCalendarStore.isBusy)
        }
    }

    private var googleAccountSubtitle: String {
        if !googleCalendarStore.isConfigured {
            return L10n.googleCalendarClientIDMissingMessage
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
            .buttonStyle(.borderedProminent)
            .disabled(macCalendarStore.isBusy)
        } else {
            Button(L10n.googleCalendarRetry) {
                Task {
                    await macCalendarStore.refreshIfNeeded(force: true)
                }
            }
            .buttonStyle(.bordered)
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

    private func googleCalendarSelectionBinding(for id: String) -> Binding<Bool> {
        Binding {
            googleCalendarStore.selectedCalendarIDs.contains(id)
        } set: { isSelected in
            let wasSelected = googleCalendarStore.selectedCalendarIDs.contains(id)
            guard isSelected != wasSelected else { return }
            googleCalendarStore.toggleCalendarSelection(id: id)
        }
    }

    private func macCalendarSelectionBinding(for id: String) -> Binding<Bool> {
        Binding {
            macCalendarStore.selectedCalendarIDs.contains(id)
        } set: { isSelected in
            let wasSelected = macCalendarStore.selectedCalendarIDs.contains(id)
            guard isSelected != wasSelected else { return }
            macCalendarStore.toggleCalendarSelection(id: id)
        }
    }

    private func refreshEnabledSources(force: Bool = false) async {
        if settings.isCalendarSourceEnabled(.google) {
            await googleCalendarStore.refreshIfNeeded(force: force)
        }

        if settings.isCalendarSourceEnabled(.macOS) {
            await macCalendarStore.refreshIfNeeded(force: force)
        }
    }
}

private struct CalendarSelectionToggle: View {
    let calendar: CalendarListItem
    @Binding var isSelected: Bool

    var body: some View {
        Toggle(isOn: $isSelected) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(calendar.colorHex.map(Color.init(hex:)) ?? Color.accentColor)
                        .frame(width: 10, height: 10)

                    Text(calendar.title)
                }

                if calendar.isPrimary {
                    Text(L10n.calendarPrimaryCalendar)
                }
            }
        }
        .toggleStyle(.checkbox)
    }
}
