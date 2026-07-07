import SwiftUI

struct CalendarSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var googleCalendarStore = GoogleCalendarStore.shared
    @ObservedObject private var macCalendarStore = MacCalendarStore.shared

    var body: some View {
        SettingsPage {
            SettingsSection(
                title: L10n.calendarSources,
                description: L10n.calendarSourcesDescription
            ) {
                SettingsCard {
                    ForEach(Array(CalendarSource.allCases.enumerated()), id: \.element.id) { index, source in
                        SettingsToggleRow(
                            title: source.displayName,
                            description: calendarSourceDescription(for: source),
                            isOn: calendarSourceBinding(for: source)
                        )

                        if index < CalendarSource.allCases.count - 1 {
                            Divider()
                        }
                    }
                }
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
    }

    @ViewBuilder
    private var googleCalendarSettings: some View {
        SettingsSection(
            title: L10n.googleCalendar,
            description: L10n.googleCalendarSettingsDescription
        ) {
            SettingsCard {
                googleConnectionRow

                if let message = googleCalendarStore.lastErrorMessage {
                    Divider()

                    SettingsStatusMessage(
                        text: message,
                        systemImage: "exclamationmark.triangle",
                        tint: .orange
                    )
                    .padding(20)
                }
            }
        }

        if googleCalendarStore.isAuthorized {
            SettingsSection(
                title: L10n.googleCalendarDisplayCalendars,
                description: L10n.googleCalendarDisplayCalendarsDescription
            ) {
                SettingsCard {
                    if googleCalendarStore.isBusy, googleCalendarStore.availableCalendars.isEmpty {
                        ProgressView(L10n.googleCalendarLoading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                    } else if googleCalendarStore.availableCalendars.isEmpty {
                        Text(L10n.googleCalendarNoCalendars)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                    } else {
                        ForEach(Array(googleCalendarStore.availableCalendars.enumerated()), id: \.element.id) { index, calendar in
                            CalendarSelectionRow(
                                calendar: calendar,
                                isSelected: googleCalendarStore.selectedCalendarIDs.contains(calendar.id)
                            ) {
                                googleCalendarStore.toggleCalendarSelection(id: calendar.id)
                            }

                            if index < googleCalendarStore.availableCalendars.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var macCalendarSettings: some View {
        SettingsSection(
            title: L10n.macOSCalendar,
            description: L10n.macOSCalendarSettingsDescription
        ) {
            SettingsCard {
                macCalendarAccessRow

                if let message = macCalendarStore.lastErrorMessage {
                    Divider()

                    SettingsStatusMessage(
                        text: message,
                        systemImage: "exclamationmark.triangle",
                        tint: .orange
                    )
                    .padding(20)
                }
            }
        }

        if macCalendarStore.isAuthorized {
            SettingsSection(
                title: L10n.googleCalendarDisplayCalendars,
                description: L10n.macOSCalendarDisplayCalendarsDescription
            ) {
                SettingsCard {
                    if macCalendarStore.isBusy, macCalendarStore.availableCalendars.isEmpty {
                        ProgressView(L10n.macOSCalendarLoading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                    } else if macCalendarStore.availableCalendars.isEmpty {
                        Text(L10n.macOSCalendarNoCalendars)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                    } else {
                        ForEach(Array(macCalendarStore.availableCalendars.enumerated()), id: \.element.id) { index, calendar in
                            CalendarSelectionRow(
                                calendar: calendar,
                                isSelected: macCalendarStore.selectedCalendarIDs.contains(calendar.id)
                            ) {
                                macCalendarStore.toggleCalendarSelection(id: calendar.id)
                            }

                            if index < macCalendarStore.availableCalendars.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }

    private var googleConnectionRow: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text(googleCalendarStore.account?.displayName ?? L10n.googleCalendarNotConnected)
                    .font(.headline)

                Text(googleAccountSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            googleActionButton
        }
        .padding(20)
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
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text(macCalendarStore.isAuthorized ? L10n.macOSCalendarAccessGranted : L10n.macOSCalendarAccessNotGranted)
                    .font(.headline)

                Text(macCalendarSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            macCalendarActionButton
        }
        .padding(20)
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

    private func refreshEnabledSources(force: Bool = false) async {
        if settings.isCalendarSourceEnabled(.google) {
            await googleCalendarStore.refreshIfNeeded(force: force)
        }

        if settings.isCalendarSourceEnabled(.macOS) {
            await macCalendarStore.refreshIfNeeded(force: force)
        }
    }
}

private struct CalendarSelectionRow: View {
    let calendar: CalendarListItem
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 16) {
                Circle()
                    .fill(calendar.colorHex.map(Color.init(hex:)) ?? Color.accentColor)
                    .frame(width: 10, height: 10)

                VStack(alignment: .leading, spacing: 4) {
                    Text(calendar.title)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    if calendar.isPrimary {
                        Text(L10n.calendarPrimaryCalendar)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .padding(20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
