import AppKit
import Combine
import CryptoKit
import DahliaRuntimeSupport
import Foundation

@MainActor
final class GoogleCalendarStore: ObservableObject {
    /// The selection saved before it became per account; read only as each account's default.
    static let selectedCalendarIDsKey = "googleCalendarSelectedCalendarIDs"

    /// Each account reaches Google by its own route, possibly as another Google account, so each keeps its selection.
    static var accountSelectedCalendarIDsKey: String {
        "\(selectedCalendarIDsKey).\(AppAccount.key)"
    }

    enum State: Equatable {
        case unconfigured
        case signedOut
        case loading
        case needsCalendarSelection
        case loaded
        case failed
    }

    static let shared = GoogleCalendarStore(
        eventsCacheDirectory: DahliaApplicationSupport.currentDirectoryURL.appending(path: "Caches/GoogleCalendar", directoryHint: .isDirectory)
    )

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

    var usesDatabricksProxy: Bool {
        (signInProvider as? DatabricksProxyGoogleSignInProvider)?.isProxyActive == true
    }

    var databricksConnectionPageURL: URL? {
        (signInProvider as? DatabricksProxyGoogleSignInProvider)?.connectionPageURL
    }

    /// Disconnect stays available while this is true, even when the proxy route is failing or not yet granted.
    var restoresThroughDatabricksProxy: Bool {
        (signInProvider as? DatabricksProxyGoogleSignInProvider)?.restoresThroughProxy == true
    }

    private let signInProvider: any GoogleSignInProviding
    private let apiClient: any GoogleCalendarAPIClientProviding
    private let userDefaults: UserDefaults
    /// The account whose selection is loaded; a load still running for the previous account saves to it, not the new one.
    private let now: () -> Date
    private let refreshInterval: TimeInterval
    private let daysAhead: Int
    private let presentingWindowProvider: @MainActor () -> NSWindow?
    private var currentSession: GoogleSession?
    private var lastRefreshAt: Date?
    private var didAttemptRestore = false
    private var isDisconnecting = false
    private var isLoadingAccountData = false
    private var authChangeObserver: GoogleAuthSessionObserver?
    private var providerChangeObserver: AnyCancellable?
    private var provider: GoogleCalendarProvider?
    private var refreshGeneration: UInt64 = 0
    private var refreshTask: Task<Void, Never>?
    private var refreshTaskID: UUID?
    /// Holds the last fetched events per account, shown while a launch or account switch restores the session.
    /// One small file replaced whole: the events are a disposable snapshot, so they stay out of SQLite and UserDefaults.
    private let eventsCacheDirectory: URL?
    private let cachedEventsLoader: @Sendable (URL) async -> [CalendarEvent]
    private var cachedEventsSnapshot: [CalendarEvent]?
    private var eventsCacheWriteTask: Task<Void, Never>?

    init(
        signInProvider: any GoogleSignInProviding = DatabricksProxyGoogleSignInProvider(),
        apiClient: any GoogleCalendarAPIClientProviding = GoogleCalendarAPIClient(),
        userDefaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        refreshInterval: TimeInterval = 300,
        daysAhead: Int = 7,
        presentingWindowProvider: @escaping @MainActor () -> NSWindow? = { NSApp.keyWindow ?? NSApp.mainWindow },
        eventsCacheDirectory: URL? = nil,
        providerChangeNotification: Notification.Name = GoogleCalendarProvider.didChange,
        cachedEventsLoader: @escaping @Sendable (URL) async -> [CalendarEvent] = GoogleCalendarStore.readCachedEvents
    ) {
        self.eventsCacheDirectory = eventsCacheDirectory
        self.cachedEventsLoader = cachedEventsLoader
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
        authChangeObserver = GoogleAuthSessionObserver(notificationName: sessionDidChangeNotification) { [weak self] forceSignOut in
            await self?.handleAuthSessionChanged(forceSignOut: forceSignOut)
        }
        provider = GoogleCalendarProvider.current(defaults: userDefaults)
        providerChangeObserver = NotificationCenter.default.publisher(for: providerChangeNotification)
            .sink { [weak self] _ in self?.reloadIfProviderChanged() }
    }

    func restoreSessionIfNeeded() async {
        await restoreSessionIfNeeded(startedByRefreshTask: false)
    }

    /// Startup constructs the store before the account migration copies its saved calendar selection.
    func reloadSelectedCalendarsAfterMigration() {
        selectedCalendarIDs = Self.loadSelectedCalendarIDs(from: userDefaults)
    }

    private func restoreSessionIfNeeded(startedByRefreshTask: Bool) async {
        guard !isDisconnecting, !didAttemptRestore else { return }
        didAttemptRestore = true

        guard isConfigured else {
            transitionToUnconfiguredState()
            return
        }

        guard await signInProvider.hasPreviousSignIn else {
            recomputeState()
            return
        }

        let generation = beginAccountDataLoad(cancelRefreshTask: !startedByRefreshTask)
        defer {
            if isCurrentRefresh(generation) { isLoadingAccountData = false }
        }
        do {
            let session = try await signInProvider.restorePreviousSignIn()
            guard isCurrentRefresh(generation) else { return }
            applySession(session)
            if session.hasScopes(GoogleOAuthScope.calendar), upcomingEvents.isEmpty, !selectedCalendarIDs.isEmpty,
               let url = eventsCacheURL() {
                let cached = await cachedEventsLoader(url)
                guard isCurrentRefresh(generation) else { return }
                cachedEventsSnapshot = cached
                let currentDate = now()
                upcomingEvents = cached.filter { $0.endDate > currentDate && selectedCalendarIDs.contains($0.calendarID) }
            }
            try await loadAccountData(session: session, generation: generation)
        } catch GoogleSignInError.noPreviousSignIn {
            guard isCurrentRefresh(generation) else { return }
            clearRuntimeState(clearSelection: false)
            recomputeState()
        } catch {
            guard isCurrentRefresh(generation) else { return }
            didAttemptRestore = false
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
            try await loadAccountData(session: session, generation: generation)
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
        if isLoadingAccountData {
            if let refreshTask {
                await refreshTask.value
            }
            return
        }

        if !force, let refreshTask, !refreshTask.isCancelled {
            if lastRefreshAt == nil {
                await refreshTask.value
            }
            return
        }

        if force {
            refreshTask?.cancel()
        }
        let taskID = UUID.v7()
        let task = Task { [weak self] in
            guard let self else { return }
            await performRefresh(force: force)
        }
        refreshTaskID = taskID
        refreshTask = task
        await task.value
        guard refreshTaskID == taskID else { return }
        refreshTask = nil
        refreshTaskID = nil
    }

    private func performRefresh(force: Bool) async {
        guard !isDisconnecting, !isLoadingAccountData else { return }
        guard isConfigured else {
            transitionToUnconfiguredState()
            return
        }

        guard currentSession != nil else {
            if !didAttemptRestore, await signInProvider.hasPreviousSignIn {
                await restoreSessionIfNeeded(startedByRefreshTask: true)
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

        if !force,
           let lastRefreshAt,
           now().timeIntervalSince(lastRefreshAt) < refreshInterval {
            recomputeStateIfNeeded()
            return
        }

        refreshGeneration &+= 1
        let generation = refreshGeneration
        beginLoadingIfNeeded()
        do {
            guard let session = try await signInProvider.refreshCurrentSession() else {
                guard isCurrentRefresh(generation) else { return }
                clearRuntimeState(clearSelection: false)
                recomputeState()
                return
            }
            guard isCurrentRefresh(generation) else { return }
            try await loadAccountData(session: session, generation: generation)
        } catch is CancellationError {
            guard isCurrentRefresh(generation) else { return }
            if lastRefreshAt != nil {
                recomputeState()
            }
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

    /// Every attempt reads metadata before events; authentication alone never means a list was loaded.
    private func loadAccountData(session: GoogleSession, generation: UInt64) async throws {
        guard isCurrentRefresh(generation) else { return }
        applySession(session)
        if lastErrorMessage != nil { lastErrorMessage = nil }

        guard session.hasScopes(GoogleOAuthScope.calendar) else {
            if !availableCalendars.isEmpty { availableCalendars = [] }
            if !upcomingEvents.isEmpty { upcomingEvents = [] }
            lastRefreshAt = nil
            recomputeState()
            return
        }

        let calendars = try await apiClient.fetchCalendarList(session: session)
        guard isCurrentRefresh(generation) else { return }
        if availableCalendars != calendars { availableCalendars = calendars }
        pruneSelectedCalendars()
        isLoadingAccountData = false
        await refreshEvents(session: session, generation: generation)
    }

    private func refreshEvents(session: GoogleSession, generation: UInt64) async {
        guard !selectedCalendarIDs.isEmpty else {
            if !upcomingEvents.isEmpty { upcomingEvents = [] }
            lastRefreshAt = nil
            recomputeState()
            return
        }

        do {
            let selectedCalendars = availableCalendars.filter { selectedCalendarIDs.contains($0.id) }
            let events = try await apiClient.fetchUpcomingEvents(
                session: session,
                calendars: selectedCalendars,
                now: now(),
                daysAhead: daysAhead
            )
            guard isCurrentRefresh(generation) else { return }
            if upcomingEvents != events { upcomingEvents = events }
            writeEventsCache(events)
            lastRefreshAt = now()
            if lastErrorMessage != nil { lastErrorMessage = nil }
            recomputeState()
        } catch is CancellationError {
            guard isCurrentRefresh(generation) else { return }
            if lastRefreshAt != nil {
                recomputeState()
            }
        } catch {
            guard isCurrentRefresh(generation) else { return }
            handle(error)
            recomputeStateIfNeeded()
        }
    }

    /// A route can retain its ID while its Google grant changes.
    private func applySession(_ session: GoogleSession) {
        let canReuseProjection = session.isAccountIdentityVerified && currentSession?.isAccountIdentityVerified == true
            && currentSession?.account.id == session.account.id
        let identityChanged = !canReuseProjection
        if identityChanged {
            beginLoading()
            availableCalendars = []
            upcomingEvents = []
            cachedEventsSnapshot = nil
            lastRefreshAt = nil
        }
        currentSession = session
        if account != session.account { account = session.account }
    }

    private func beginLoading() {
        if lastErrorMessage != nil { lastErrorMessage = nil }
        if state != .loading { state = .loading }
    }

    private func beginLoadingIfNeeded() {
        guard lastRefreshAt == nil || state == .failed else { return }
        beginLoading()
    }

    private func beginAccountDataLoad(cancelRefreshTask: Bool = true) -> UInt64 {
        invalidateCurrentRefresh(cancelTask: cancelRefreshTask)
        isLoadingAccountData = true
        beginLoading()
        return refreshGeneration
    }

    private func handle(_ error: Error) {
        if case GoogleCalendarAPIError.proxyGoogleAuthenticationRequired = error {
            clearRuntimeState(clearSelection: false)
        }
        // A Google credential revoked on the Databricks connection page surfaces on whichever proxy request runs next;
        // it ends the session rather than failing it, so Connect starts the Databricks sign-in again.
        if let error = error as? GoogleCalendarAPIError, DatabricksProxyGoogleSignInProvider.isNotAuthorized(error) {
            clearRuntimeState(clearSelection: false)
            if lastErrorMessage != nil { lastErrorMessage = nil }
            state = .signedOut
            return
        }
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
        if clearSelection { writeEventsCache(nil) }
        currentSession = nil
        if account != nil { account = nil }
        if !availableCalendars.isEmpty { availableCalendars = [] }
        if !upcomingEvents.isEmpty { upcomingEvents = [] }
        lastRefreshAt = nil

        if clearSelection {
            updateSelectedCalendarIDs([])
        }
    }

    /// The route changes with the account: drop the previous account's session, calendars, events, and every load still
    /// running for it before any of them can publish, then restore with the new account's selection and route.
    /// Another provider reads Google Calendar now: its own sign-in, calendars, and cached events.
    @discardableResult
    private func reloadIfProviderChanged() -> Bool {
        let current = GoogleCalendarProvider.current(defaults: userDefaults)
        guard current != provider else { return false }
        provider = current
        clearRuntimeState(clearSelection: false)
        cachedEventsSnapshot = nil
        didAttemptRestore = false
        recomputeState()
        Task { await restoreSessionIfNeeded() }
        return true
    }

    private func handleAuthSessionChanged(forceSignOut: Bool) async {
        if reloadIfProviderChanged() { return }
        didAttemptRestore = false
        guard !isDisconnecting else { return }
        guard !forceSignOut, await signInProvider.hasPreviousSignIn else {
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
        guard selectedCalendarIDs != filtered else { return }
        selectedCalendarIDs = filtered
        Self.persistSelectedCalendarIDs(filtered, to: userDefaults)
    }

    private func pruneSelectedCalendars() {
        updateSelectedCalendarIDs(selectedCalendarIDs, pruneUnavailable: true)
    }

    private func invalidateCurrentRefresh(cancelTask: Bool = true) {
        refreshGeneration &+= 1
        isLoadingAccountData = false
        guard cancelTask else { return }
        refreshTask?.cancel()
        refreshTask = nil
        refreshTaskID = nil
    }

    private func isCurrentRefresh(_ generation: UInt64) -> Bool {
        generation == refreshGeneration
    }

    func waitForEventsCacheWrite() async {
        await eventsCacheWriteTask?.value
    }

    private var eventsCachePrefix: String {
        let identity = provider?.databricksConnectionID.map { "databricks-\($0.uuidString)" } ?? "google"
        return "\(AppAccount.key)-\(identity)-"
    }

    private func eventsCacheURL() -> URL? {
        guard let session = currentSession, session.isAccountIdentityVerified else { return nil }
        let accountID = session.account.id
        let principal = SHA256.hash(data: Data(accountID.utf8)).map { String(format: "%02x", $0) }.joined()
        return eventsCacheDirectory?.appending(path: "\(eventsCachePrefix)\(principal).json")
    }

    /// Ordered off MainActor; disconnect removes this provider's snapshots even when session verification failed.
    private func writeEventsCache(_ events: [CalendarEvent]?) {
        guard let directory = eventsCacheDirectory else { return }
        let url = eventsCacheURL()
        if let events {
            guard url != nil else { return }
            if cachedEventsSnapshot == events { return }
        }
        cachedEventsSnapshot = events
        let prefix = eventsCachePrefix
        let previousTask = eventsCacheWriteTask
        eventsCacheWriteTask = Task.detached {
            await previousTask?.value
            guard let events, let url else {
                let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
                for file in files where file.lastPathComponent.hasPrefix(prefix) && file.pathExtension == "json" {
                    try? FileManager.default.removeItem(at: file)
                }
                return
            }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? JSONEncoder().encode(events).write(to: url, options: .atomic)
        }
    }

    private nonisolated static func readCachedEvents(at url: URL) async -> [CalendarEvent] {
        await Task.detached {
            guard let data = try? Data(contentsOf: url),
                  let events = try? JSONDecoder().decode([CalendarEvent].self, from: data)
            else { return [] }
            return events
        }.value
    }

    private static func loadSelectedCalendarIDs(from userDefaults: UserDefaults) -> Set<String> {
        let json = userDefaults.string(forKey: accountSelectedCalendarIDsKey) ?? userDefaults.string(forKey: selectedCalendarIDsKey)
        guard let json,
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
        userDefaults.set(json, forKey: Self.accountSelectedCalendarIDsKey)
    }
}
