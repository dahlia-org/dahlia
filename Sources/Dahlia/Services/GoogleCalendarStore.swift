import AppKit
import Combine
import Foundation

@MainActor
final class GoogleCalendarStore: ObservableObject {
    static let selectedCalendarIDsKey = "googleCalendarSelectedCalendarIDs"

    enum State: Equatable {
        case unconfigured
        case signedOut
        case loading
        case needsCalendarSelection
        case loaded
        case failed
    }

    static let shared = GoogleCalendarStore()

    @Published private(set) var state: State
    @Published private(set) var account: GoogleCalendarAccount?
    @Published private(set) var availableCalendars: [CalendarListItem] = []
    @Published private(set) var upcomingEvents: [CalendarEvent] = []
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var selectedCalendarIDs: Set<String>

    var isAuthorized: Bool {
        currentSession?.hasScopes(GoogleOAuthScope.calendar) == true
    }

    var isConfigured: Bool {
        signInProvider.isConfigured
    }

    var isBusy: Bool {
        state == .loading
    }

    private let signInProvider: any GoogleSignInProviding
    private let apiClient: any GoogleCalendarAPIClientProviding
    private let userDefaults: UserDefaults
    private let now: () -> Date
    private let refreshInterval: TimeInterval
    private let daysAhead: Int
    private let presentingWindowProvider: @MainActor () -> NSWindow?
    private var currentSession: GoogleSession?
    private var lastRefreshAt: Date?
    private var didAttemptRestore = false
    private var isDisconnecting = false
    private var isLoadingAccountData = false
    private var authChangeTask: Task<Void, Never>?
    private var refreshGeneration: UInt64 = 0

    init(
        signInProvider: any GoogleSignInProviding = GoogleSignInAdapter(sessionKind: .calendar),
        apiClient: any GoogleCalendarAPIClientProviding = GoogleCalendarAPIClient(),
        userDefaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        refreshInterval: TimeInterval = 300,
        daysAhead: Int = 7,
        presentingWindowProvider: @escaping @MainActor () -> NSWindow? = { NSApp.keyWindow ?? NSApp.mainWindow }
    ) {
        self.signInProvider = signInProvider
        self.apiClient = apiClient
        self.userDefaults = userDefaults
        self.now = now
        self.refreshInterval = refreshInterval
        self.daysAhead = daysAhead
        self.presentingWindowProvider = presentingWindowProvider
        let sessionDidChangeNotification = signInProvider.sessionDidChangeNotification
        self.selectedCalendarIDs = Self.loadSelectedCalendarIDs(from: userDefaults)
        self.state = signInProvider.isConfigured ? .signedOut : .unconfigured
        authChangeTask = Task { [weak self] in
            for await notification in NotificationCenter.default.notifications(named: sessionDidChangeNotification) {
                await self?.handleAuthSessionChanged(
                    forceSignOut: notification.object as? GoogleAuthSessionChangeReason == .disconnected
                )
            }
        }
    }

    deinit {
        authChangeTask?.cancel()
    }

    func restoreSessionIfNeeded() async {
        guard !isDisconnecting, !didAttemptRestore else { return }
        didAttemptRestore = true

        guard isConfigured else {
            transitionToUnconfiguredState()
            return
        }

        guard signInProvider.hasPreviousSignIn else {
            recomputeState()
            return
        }

        let generation = beginAccountDataLoad()
        defer { isLoadingAccountData = false }
        do {
            let session = try await signInProvider.restorePreviousSignIn()
            guard isCurrentRefresh(generation) else { return }
            try await loadAccountData(session: session, refreshEvents: true, generation: generation)
        } catch GoogleSignInError.noPreviousSignIn {
            guard isCurrentRefresh(generation) else { return }
            clearRuntimeState(clearSelection: false)
            recomputeState()
        } catch {
            guard isCurrentRefresh(generation) else { return }
            handle(error)
            clearRuntimeState(clearSelection: false)
            recomputeStateIfNeeded()
        }
    }

    func signIn() async {
        guard !isDisconnecting else { return }
        guard isConfigured else {
            transitionToUnconfiguredState()
            return
        }

        guard let presentingWindow = presentingWindowProvider() else {
            handle(GoogleSignInError.missingPresentingWindow)
            return
        }

        let generation = beginAccountDataLoad()
        defer { isLoadingAccountData = false }
        do {
            let session = try await signInProvider.signIn(
                withPresentingWindow: presentingWindow,
                requestedScopes: GoogleOAuthScope.calendar
            )
            guard isCurrentRefresh(generation) else { return }
            try await loadAccountData(session: session, refreshEvents: true, generation: generation)
        } catch {
            guard isCurrentRefresh(generation) else { return }
            handle(error)
            recomputeStateIfNeeded()
        }
    }

    func disconnect() async {
        guard !isDisconnecting else { return }
        isDisconnecting = true
        clearRuntimeState(clearSelection: true)
        let generation = refreshGeneration
        beginLoading()
        defer { isDisconnecting = false }
        do {
            try await signInProvider.disconnect()
        } catch {
            guard isCurrentRefresh(generation) else { return }
            handle(error)
        }

        guard isCurrentRefresh(generation) else { return }
        recomputeState()
    }

    func refreshIfNeeded(force: Bool = false) async {
        guard !isDisconnecting, !isLoadingAccountData else { return }
        guard isConfigured else {
            transitionToUnconfiguredState()
            return
        }

        guard currentSession != nil else {
            if !didAttemptRestore, signInProvider.hasPreviousSignIn {
                await restoreSessionIfNeeded()
                return
            }

            recomputeState()
            return
        }

        guard isAuthorized else {
            if !upcomingEvents.isEmpty { upcomingEvents = [] }
            lastRefreshAt = nil
            recomputeState()
            return
        }

        guard !selectedCalendarIDs.isEmpty else {
            if !upcomingEvents.isEmpty { upcomingEvents = [] }
            lastRefreshAt = nil
            recomputeState()
            return
        }

        if !force,
           let lastRefreshAt,
           now().timeIntervalSince(lastRefreshAt) < refreshInterval {
            recomputeStateIfNeeded()
            return
        }

        refreshGeneration &+= 1
        let generation = refreshGeneration
        beginLoading()
        do {
            guard let session = try await signInProvider.refreshCurrentSession() ?? currentSession else {
                guard isCurrentRefresh(generation) else { return }
                clearRuntimeState(clearSelection: false)
                recomputeState()
                return
            }
            guard isCurrentRefresh(generation) else { return }

            currentSession = session
            account = session.account
            let selectedCalendars = availableCalendars.filter { selectedCalendarIDs.contains($0.id) }
            let events = try await apiClient.fetchUpcomingEvents(
                accessToken: session.accessToken,
                calendars: selectedCalendars,
                now: now(),
                daysAhead: daysAhead
            )
            guard isCurrentRefresh(generation) else { return }
            upcomingEvents = events
            lastRefreshAt = now()
            lastErrorMessage = nil
            recomputeState()
        } catch {
            guard isCurrentRefresh(generation) else { return }
            handle(error)
            recomputeStateIfNeeded()
        }
    }

    func toggleCalendarSelection(id: String) {
        guard isAuthorized else { return }
        var nextSelection = selectedCalendarIDs
        nextSelection.toggle(id)

        invalidateCurrentRefresh()
        updateSelectedCalendarIDs(nextSelection)
        Task {
            await refreshIfNeeded(force: true)
        }
    }

    func setCalendarSelection(_ ids: Set<String>) {
        guard isAuthorized else { return }
        invalidateCurrentRefresh()
        updateSelectedCalendarIDs(ids)
        Task {
            await refreshIfNeeded(force: true)
        }
    }

    private func loadAccountData(
        session: GoogleSession,
        refreshEvents: Bool,
        generation: UInt64
    ) async throws {
        guard isCurrentRefresh(generation) else { return }
        currentSession = session
        account = session.account
        lastErrorMessage = nil

        guard session.hasScopes(GoogleOAuthScope.calendar) else {
            if !availableCalendars.isEmpty { availableCalendars = [] }
            if !upcomingEvents.isEmpty { upcomingEvents = [] }
            lastRefreshAt = nil
            recomputeState()
            return
        }

        let calendars = try await apiClient.fetchCalendarList(accessToken: session.accessToken)
        guard isCurrentRefresh(generation) else { return }
        availableCalendars = calendars
        pruneSelectedCalendars()
        isLoadingAccountData = false

        if refreshEvents {
            if selectedCalendarIDs.isEmpty {
                if !upcomingEvents.isEmpty { upcomingEvents = [] }
                lastRefreshAt = nil
                recomputeState()
            } else {
                await refreshIfNeeded(force: true)
            }
        } else {
            recomputeState()
        }
    }

    private func beginLoading() {
        lastErrorMessage = nil
        state = .loading
    }

    private func beginAccountDataLoad() -> UInt64 {
        invalidateCurrentRefresh()
        isLoadingAccountData = true
        beginLoading()
        return refreshGeneration
    }

    private func handle(_ error: Error) {
        lastErrorMessage = GoogleAuthErrorFormatter.message(for: error, defaultMessage: L10n.googleCalendarUnexpectedResponse)
        state = .failed
        ErrorReportingService.captureSanitized(.googleCalendar)
    }

    private func recomputeState() {
        let newState: State = if !isConfigured {
            .unconfigured
        } else if currentSession == nil || !isAuthorized {
            .signedOut
        } else if !availableCalendars.isEmpty, selectedCalendarIDs.isEmpty {
            .needsCalendarSelection
        } else {
            .loaded
        }
        if state != newState {
            state = newState
        }
    }

    private func recomputeStateIfNeeded() {
        guard state != .loading else { return }
        if state != .failed {
            recomputeState()
        }
    }

    private func transitionToUnconfiguredState() {
        clearRuntimeState(clearSelection: true)
        state = .unconfigured
    }

    private func clearRuntimeState(clearSelection: Bool) {
        invalidateCurrentRefresh()
        currentSession = nil
        if account != nil { account = nil }
        if !availableCalendars.isEmpty { availableCalendars = [] }
        if !upcomingEvents.isEmpty { upcomingEvents = [] }
        lastRefreshAt = nil

        if clearSelection {
            updateSelectedCalendarIDs([])
        }
    }

    private func handleAuthSessionChanged(forceSignOut: Bool) async {
        didAttemptRestore = false
        guard !isDisconnecting else { return }
        guard !forceSignOut, signInProvider.hasPreviousSignIn else {
            clearRuntimeState(clearSelection: forceSignOut)
            recomputeState()
            return
        }
        await restoreSessionIfNeeded()
    }

    private func updateSelectedCalendarIDs(_ ids: Set<String>, pruneUnavailable: Bool = false) {
        let availableIDs = Set(availableCalendars.map(\.id))
        let filtered = if pruneUnavailable {
            ids.intersection(availableIDs)
        } else {
            availableIDs.isEmpty ? ids : ids.intersection(availableIDs)
        }
        selectedCalendarIDs = filtered
        Self.persistSelectedCalendarIDs(filtered, to: userDefaults)
    }

    private func pruneSelectedCalendars() {
        updateSelectedCalendarIDs(selectedCalendarIDs, pruneUnavailable: true)
    }

    private func invalidateCurrentRefresh() {
        refreshGeneration &+= 1
    }

    private func isCurrentRefresh(_ generation: UInt64) -> Bool {
        generation == refreshGeneration
    }

    private static func loadSelectedCalendarIDs(from userDefaults: UserDefaults) -> Set<String> {
        guard let json = userDefaults.string(forKey: selectedCalendarIDsKey),
              let data = json.data(using: .utf8),
              let ids = try? JSONDecoder().decode([String].self, from: data)
        else {
            return []
        }
        return Set(ids)
    }

    private static func persistSelectedCalendarIDs(_ ids: Set<String>, to userDefaults: UserDefaults) {
        let sorted = Array(ids).sorted()
        guard let data = try? JSONEncoder().encode(sorted),
              let json = String(data: data, encoding: .utf8)
        else {
            return
        }
        userDefaults.set(json, forKey: Self.selectedCalendarIDsKey)
    }
}
