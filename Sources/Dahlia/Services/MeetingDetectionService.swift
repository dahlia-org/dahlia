import AppKit
import Combine
import CoreAudio
import CoreGraphics
import Foundation

/// マイク使用・ミーティングアプリ・ウィンドウタイトルを組み合わせて会議を検出し、
/// カレンダー予定とともに macOS の標準通知へ接続する。
@MainActor
final class MeetingDetectionService: ObservableObject {
    private static let meetingBundleIDs: Set = [
        "us.zoom.xos",
        "com.microsoft.teams2",
        "com.microsoft.teams",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "Cisco-Systems.Spark",
        "com.apple.FaceTime",
    ]

    private static let windowTitlePatterns: [(pattern: String, appName: String)] = [
        ("Meet - ", "Google Meet"),
        ("Google Meet", "Google Meet"),
        ("(Meeting) | Microsoft Teams", "Microsoft Teams"),
        ("Zoom Meeting", "Zoom"),
        ("Zoom Webinar", "Zoom"),
        ("Cisco Webex", "Webex"),
    ]

    private static let meetCodeRegex: NSRegularExpression = {
        do {
            return try NSRegularExpression(pattern: "[a-z]{3}-[a-z]{4}-[a-z]{3}")
        } catch {
            preconditionFailure("Invalid Google Meet code regular expression: \(error)")
        }
    }()

    private static let browserNames: Set = [
        "Google Chrome", "Safari", "Microsoft Edge", "Arc", "Firefox",
        "Brave Browser", "Chromium", "Vivaldi", "Opera",
    ]

    var isRecording: () -> Bool = { false }

    private var monitoredDeviceIDs: [AudioDeviceID] = []
    private var microphoneMonitoringID: UUID?
    @Published private var isMicrophoneInUse = false
    @Published private var activeMeetingAppName: String?
    @Published private var windowDetectedMeetingName: String?
    private var suppressed = false
    private var microphoneNotificationAttemptID: UUID?
    private var notificationSettingsSignature: String?
    private var detectionCancellables = Set<AnyCancellable>()
    private var lifecycleCancellables = Set<AnyCancellable>()
    private var windowScanTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var calendarRefreshTask: Task<Void, Never>?
    private var calendarSettingsRefreshTask: Task<Void, Never>?
    private var calendarSchedulingTask: Task<Void, Never>?
    private var notificationAuthorizationTask: Task<Void, Never>?
    private var microphoneDeviceRegistrationTask: Task<Void, Never>?
    private var microphoneStatusCheckTask: Task<Void, Never>?
    private var isStarted = false
    private var isMicrophoneDetectionRunning = false
    private let notificationService: MeetingNotificationService
    private let now: () -> Date

    init(
        notificationService: MeetingNotificationService = .shared,
        now: @escaping () -> Date = { .now }
    ) {
        self.notificationService = notificationService
        self.now = now
    }

    func start() {
        guard !isStarted else {
            reconcileSettings()
            return
        }

        isStarted = true
        observeSettings()
        observeCalendarEvents()
        startCalendarRefreshLoop()
        reconcileSettings()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        lifecycleCancellables.removeAll()
        stopMicrophoneDetection()
        calendarRefreshTask?.cancel()
        calendarRefreshTask = nil
        calendarSettingsRefreshTask?.cancel()
        calendarSettingsRefreshTask = nil
        calendarSchedulingTask?.cancel()
        calendarSchedulingTask = nil
        notificationAuthorizationTask?.cancel()
        notificationAuthorizationTask = nil
        notificationSettingsSignature = nil

        Task {
            await notificationService.cancelCalendarNotifications()
        }
    }

    private func observeSettings() {
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.reconcileSettings()
                }
            }
            .store(in: &lifecycleCancellables)
    }

    private func observeCalendarEvents() {
        Publishers.CombineLatest(
            GoogleCalendarStore.shared.$upcomingEvents,
            MacCalendarStore.shared.$upcomingEvents
        )
        .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
        .sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.rescheduleCalendarNotifications()
            }
        }
        .store(in: &lifecycleCancellables)
    }

    private func reconcileSettings() {
        guard isStarted else { return }
        let settings = AppSettings.shared
        let settingsSignature = [
            settings.meetingDetectionEnabled.description,
            settings.microphoneMeetingNotificationsEnabled.description,
            settings.calendarEventMeetingNotificationsEnabled.description,
            settings.enabledCalendarSourcesJSON,
            settings.includesAllDayCalendarEvents.description,
            settings.includesCalendarEventsWithoutOtherAttendees.description,
            settings.includesCalendarEventsWithoutConferenceURI.description,
            settings.includesDeclinedCalendarEvents.description,
            settings.includesOutOfOfficeCalendarEvents.description,
            settings.appLanguageRawValue,
        ].joined(separator: "|")
        guard notificationSettingsSignature != settingsSignature else { return }
        notificationSettingsSignature = settingsSignature

        let shouldDetectMicrophone = settings.meetingDetectionEnabled
            && settings.microphoneMeetingNotificationsEnabled

        if shouldDetectMicrophone {
            startMicrophoneDetection()
        } else {
            stopMicrophoneDetection()
        }

        notificationService.refreshCategories()
        notificationAuthorizationTask?.cancel()
        if settings.meetingDetectionEnabled,
           settings.microphoneMeetingNotificationsEnabled,
           !settings.calendarEventMeetingNotificationsEnabled {
            notificationAuthorizationTask = Task {
                _ = await notificationService.requestAuthorizationIfNeeded()
            }
        }

        calendarSettingsRefreshTask?.cancel()
        if settings.meetingDetectionEnabled, settings.calendarEventMeetingNotificationsEnabled {
            calendarSettingsRefreshTask = Task { [weak self] in
                await self?.refreshEnabledCalendarSources()
            }
        }

        rescheduleCalendarNotifications()
    }

    private func startCalendarRefreshLoop() {
        calendarRefreshTask?.cancel()
        calendarRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                await self?.refreshEnabledCalendarSources()

                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    return
                }
            }
        }
    }

    private func refreshEnabledCalendarSources() async {
        let settings = AppSettings.shared
        guard settings.meetingDetectionEnabled,
              settings.calendarEventMeetingNotificationsEnabled
        else { return }

        if settings.isCalendarSourceEnabled(.google) {
            await GoogleCalendarStore.shared.refreshIfNeeded()
        }
        if settings.isCalendarSourceEnabled(.macOS) {
            await MacCalendarStore.shared.refreshIfNeeded()
        }
    }

    private func rescheduleCalendarNotifications() {
        calendarSchedulingTask?.cancel()
        let events = selectedUpcomingEvents
        calendarSchedulingTask = Task { [notificationService] in
            await notificationService.replaceCalendarNotifications(with: events)
        }
    }

    // MARK: - マイク利用による会議検出

    private func startMicrophoneDetection() {
        guard !isMicrophoneDetectionRunning else { return }
        isMicrophoneDetectionRunning = true
        startMicrophoneMonitoring()
        startAppMonitoring()
        startWindowTitleScanning()
        startCombinedDetection()
    }

    private func stopMicrophoneDetection() {
        guard isMicrophoneDetectionRunning else { return }
        isMicrophoneDetectionRunning = false
        detectionCancellables.removeAll()
        windowScanTimer?.invalidate()
        windowScanTimer = nil
        monitoredDeviceIDs.removeAll()
        if let microphoneMonitoringID {
            Task {
                await AudioHardwareQueryService.shared.stopMonitoring(ownerID: microphoneMonitoringID)
            }
        }
        microphoneMonitoringID = nil
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        isMicrophoneInUse = false
        activeMeetingAppName = nil
        windowDetectedMeetingName = nil
        suppressed = false
        microphoneNotificationAttemptID = nil
        microphoneDeviceRegistrationTask?.cancel()
        microphoneDeviceRegistrationTask = nil
        microphoneStatusCheckTask?.cancel()
        microphoneStatusCheckTask = nil
    }

    private func startMicrophoneMonitoring() {
        let monitoringID = UUID()
        microphoneMonitoringID = monitoringID
        let onDeviceListChange: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in
                self?.scheduleDeviceListenerRegistration()
            }
        }
        microphoneDeviceRegistrationTask = Task { [weak self] in
            await AudioHardwareQueryService.shared.startMonitoring(
                ownerID: monitoringID,
                onDeviceListChange: onDeviceListChange
            )
            await self?.registerDeviceListeners(monitoringID: monitoringID)
        }
    }

    private func scheduleDeviceListenerRegistration() {
        guard let monitoringID = microphoneMonitoringID else { return }
        microphoneDeviceRegistrationTask?.cancel()
        microphoneDeviceRegistrationTask = Task { [weak self] in
            await self?.registerDeviceListeners(monitoringID: monitoringID)
        }
    }

    private func registerDeviceListeners(monitoringID: UUID) async {
        let deviceIDs = await AudioHardwareQueryService.shared.inputDeviceIDs()
        guard !Task.isCancelled,
              isMicrophoneDetectionRunning,
              microphoneMonitoringID == monitoringID else { return }
        let onRunningStateChange: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in
                self?.scheduleMicrophoneStatusCheck()
            }
        }
        await AudioHardwareQueryService.shared.replaceRunningStateListeners(
            ownerID: monitoringID,
            deviceIDs: deviceIDs,
            onRunningStateChange: onRunningStateChange
        )
        guard !Task.isCancelled,
              isMicrophoneDetectionRunning,
              microphoneMonitoringID == monitoringID else { return }

        monitoredDeviceIDs = deviceIDs
        scheduleMicrophoneStatusCheck()
    }

    private func scheduleMicrophoneStatusCheck() {
        microphoneStatusCheckTask?.cancel()
        let deviceIDs = monitoredDeviceIDs
        microphoneStatusCheckTask = Task { [weak self] in
            let running = await AudioHardwareQueryService.shared.isAnyInputDeviceRunning(in: deviceIDs)
            guard !Task.isCancelled else { return }
            self?.applyMicrophoneRunningState(running)
        }
    }

    private func applyMicrophoneRunningState(_ running: Bool) {
        guard isMicrophoneDetectionRunning else { return }
        if isMicrophoneInUse != running {
            isMicrophoneInUse = running
        }
        if !running {
            suppressed = false
            microphoneNotificationAttemptID = nil
        }
    }

    private func startAppMonitoring() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        let launchObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.checkRunningMeetingApps()
            }
        }
        let terminateObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.checkRunningMeetingApps()
            }
        }

        workspaceObservers = [launchObserver, terminateObserver]
        checkRunningMeetingApps()
    }

    private func checkRunningMeetingApps() {
        let name = NSWorkspace.shared.runningApplications.first { app in
            guard let bundleIdentifier = app.bundleIdentifier else { return false }
            return Self.meetingBundleIDs.contains(bundleIdentifier)
        }?.localizedName

        if activeMeetingAppName != name {
            activeMeetingAppName = name
        }
    }

    private func startWindowTitleScanning() {
        windowScanTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.scanWindowTitles()
            }
        }
        scanWindowTitles()
    }

    private func scanWindowTitles() {
        guard !suppressed, !isRecording() else { return }
        let detected = Self.detectMeetingFromWindowTitles()
        if windowDetectedMeetingName != detected {
            windowDetectedMeetingName = detected
        }
    }

    private func startCombinedDetection() {
        Publishers.CombineLatest3(
            $isMicrophoneInUse.removeDuplicates(),
            $activeMeetingAppName.removeDuplicates(),
            $windowDetectedMeetingName.removeDuplicates()
        )
        .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
        .sink { [weak self] micActive, meetingApp, windowMeeting in
            Task { @MainActor [weak self] in
                self?.evaluateDetection(
                    micActive: micActive,
                    meetingApp: meetingApp,
                    windowMeeting: windowMeeting
                )
            }
        }
        .store(in: &detectionCancellables)
    }

    private func evaluateDetection(micActive: Bool, meetingApp: String?, windowMeeting: String?) {
        let settings = AppSettings.shared
        guard settings.meetingDetectionEnabled,
              settings.microphoneMeetingNotificationsEnabled,
              !isRecording(),
              !suppressed,
              microphoneNotificationAttemptID == nil,
              micActive,
              meetingApp != nil || windowMeeting != nil
        else { return }

        let attemptID = UUID()
        microphoneNotificationAttemptID = attemptID
        let appName = windowMeeting ?? meetingApp ?? ""
        let bundleIdentifier = NSWorkspace.shared.runningApplications.first {
            $0.localizedName == appName
        }?.bundleIdentifier ?? "unknown"
        let calendarEvent = recentCalendarEvent()
        let meeting = DetectedMeeting(
            title: calendarEvent?.resolvedMeetingTitle ?? L10n.newMeeting,
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            calendarEvent: calendarEvent
        )

        Task { [weak self, notificationService] in
            let wasDelivered = await notificationService.deliverMicrophoneDetection(meeting)
            guard let self, self.microphoneNotificationAttemptID == attemptID else { return }
            self.microphoneNotificationAttemptID = nil
            if wasDelivered {
                self.suppressed = true
            }
        }
    }

    // MARK: - Window Title Helpers

    private static func detectMeetingFromWindowTitles() -> String? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        for window in windows {
            guard let owner = window[kCGWindowOwnerName as String] as? String,
                  let title = window[kCGWindowName as String] as? String,
                  !title.isEmpty
            else { continue }

            for pattern in windowTitlePatterns where title.contains(pattern.pattern) {
                return pattern.appName
            }

            if browserNames.contains(owner) {
                let range = NSRange(title.startIndex..., in: title)
                if meetCodeRegex.firstMatch(in: title, range: range) != nil {
                    return "Google Meet"
                }
            }
        }
        return nil
    }

    private func recentCalendarEvent() -> CalendarEvent? {
        let currentDate = now()
        let windowStart = currentDate.addingTimeInterval(-300)

        return selectedUpcomingEvents
            .filter { event in
                !event.isAllDay
                    && event.startDate >= windowStart
                    && event.startDate <= currentDate
                    && event.endDate >= currentDate
            }
            .min { lhs, rhs in
                if lhs.startDate != rhs.startDate {
                    return lhs.startDate > rhs.startDate
                }
                if lhs.endDate != rhs.endDate {
                    return lhs.endDate < rhs.endDate
                }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
    }

    private var selectedUpcomingEvents: [CalendarEvent] {
        var events: [CalendarEvent] = []
        let settings = AppSettings.shared

        if settings.isCalendarSourceEnabled(.google) {
            events.append(contentsOf: GoogleCalendarStore.shared.upcomingEvents)
        }
        if settings.isCalendarSourceEnabled(.macOS) {
            events.append(contentsOf: MacCalendarStore.shared.upcomingEvents)
        }

        return events.deduplicatedAcrossSources()
    }

}
