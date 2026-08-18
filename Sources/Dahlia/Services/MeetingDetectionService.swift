import AppKit
import Combine
import Foundation

/// 入力プロセスに基づく会議候補の通知と録音停止、およびカレンダー自動録音を管理する。
@MainActor
// swiftlint:disable:next type_body_length
final class MeetingDetectionService: ObservableObject {
    var isRecording: () -> Bool = { false }
    var isActivelyRecording: () -> Bool = { false }
    var onAutomaticRecording: (CalendarEvent) -> Void = { _ in }
    var onAutomaticRecordingStop: () -> Void = {}

    private var windowDetectedBrowserContexts = Set<MeetingAudioContext>()
    private var meetingAudioSnapshot: MeetingAudioActivityMonitor.Snapshot?
    private var recordingActivityTracker = MeetingRecordingActivityTracker()
    private var notificationSettingsSignature: String?
    private var lifecycleCancellables = Set<AnyCancellable>()
    private var windowScanTimer: Timer?
    private var windowScanTask: Task<Void, Never>?
    private var windowScanTaskID: UUID?
    private var calendarPowerObservers: [NSObjectProtocol] = []
    private var calendarRefreshTask: Task<Void, Never>?
    private var calendarSourceRefreshTask: Task<Void, Never>?
    private var calendarSourceRefreshTaskID: UUID?
    private var calendarSourceRefreshGeneration: UInt64 = 0
    private var calendarSchedulingTask: Task<Void, Never>?
    private var calendarAutoRecordingTask: Task<Void, Never>?
    private var isCalendarSchedulingSuspendedForSleep = false
    private var notificationAuthorizationTask: Task<Void, Never>?
    private var meetingAudioMonitorCommandTask: Task<Void, Never>?
    private var meetingAudioMonitorCommandID: UUID?
    private var meetingAudioMonitoringGeneration: UInt64 = 0
    private var isStarted = false
    private var isRecordingLifecycleActive = false
    private var isMeetingAudioMonitoringRunning = false
    private let notificationService: MeetingNotificationService
    private let calendarAutoRecordingStore: CalendarAutoRecordingStore
    private let calendarSourceCoordinator: CalendarSourceCoordinator
    private let meetingAudioActivityMonitor: MeetingAudioActivityMonitor
    private let meetingWindowDetectionWorker: MeetingWindowDetectionWorker
    private let now: () -> Date

    init(
        notificationService: MeetingNotificationService = .shared,
        calendarAutoRecordingStore: CalendarAutoRecordingStore = .shared,
        calendarSourceCoordinator: CalendarSourceCoordinator = .shared,
        meetingAudioActivityMonitor: MeetingAudioActivityMonitor = MeetingAudioActivityMonitor(),
        meetingWindowDetectionWorker: MeetingWindowDetectionWorker = MeetingWindowDetectionWorker(),
        now: @escaping () -> Date = { .now }
    ) {
        self.notificationService = notificationService
        self.calendarAutoRecordingStore = calendarAutoRecordingStore
        self.calendarSourceCoordinator = calendarSourceCoordinator
        self.meetingAudioActivityMonitor = meetingAudioActivityMonitor
        self.meetingWindowDetectionWorker = meetingWindowDetectionWorker
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
        observeCalendarPowerEvents()
        startCalendarRefreshLoop()
        reconcileSettings()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        isRecordingLifecycleActive = false
        lifecycleCancellables.removeAll()
        stopWindowTitleScanning()
        stopMeetingAudioMonitoring()
        calendarRefreshTask?.cancel()
        calendarRefreshTask = nil
        calendarSourceRefreshGeneration &+= 1
        calendarSourceRefreshTask?.cancel()
        calendarSourceRefreshTask = nil
        calendarSourceRefreshTaskID = nil
        calendarSchedulingTask?.cancel()
        calendarSchedulingTask = nil
        calendarAutoRecordingTask?.cancel()
        calendarAutoRecordingTask = nil
        isCalendarSchedulingSuspendedForSleep = false
        let notificationCenter = NSWorkspace.shared.notificationCenter
        for observer in calendarPowerObservers {
            notificationCenter.removeObserver(observer)
        }
        calendarPowerObservers.removeAll()
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
            calendarSourceCoordinator.$eventsBySource,
            calendarAutoRecordingStore.$selections
        )
        .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
        .sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.calendarInputsDidChange()
            }
        }
        .store(in: &lifecycleCancellables)

        calendarSourceCoordinator.$loadedSources
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.rescheduleAutomaticRecording()
                }
            }
            .store(in: &lifecycleCancellables)
    }

    private func reconcileSettings() {
        guard isStarted else { return }
        let settings = AppSettings.shared
        reconcileMeetingAudioMonitoring()
        let settingsSignature = [
            settings.meetingDetectionEnabled.description,
            settings.microphoneMeetingNotificationsEnabled.description,
            settings.automaticMeetingEndRecordingStopEnabled.description,
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

        notificationService.refreshCategories()
        notificationAuthorizationTask?.cancel()
        if settings.meetingDetectionEnabled,
           settings.microphoneMeetingNotificationsEnabled,
           !settings.calendarEventMeetingNotificationsEnabled {
            notificationAuthorizationTask = Task {
                _ = await notificationService.requestAuthorizationIfNeeded()
            }
        }

        if shouldRefreshCalendarSources {
            requestCalendarSourceRefresh(force: false)
        } else {
            cancelCalendarSourceRefresh()
        }

        rescheduleCalendarNotifications()
        rescheduleAutomaticRecording()
    }

    private func startCalendarRefreshLoop() {
        calendarRefreshTask?.cancel()
        calendarRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                requestCalendarSourceRefresh(force: false, coalescesWithActiveRefresh: true)

                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    return
                }
            }
        }
    }

    private func requestCalendarSourceRefresh(
        force: Bool,
        resumesAfterWake: Bool = false,
        coalescesWithActiveRefresh: Bool = false
    ) {
        guard isStarted,
              !isCalendarSchedulingSuspendedForSleep || resumesAfterWake else { return }
        if coalescesWithActiveRefresh, calendarSourceRefreshTask != nil {
            return
        }

        calendarSourceRefreshGeneration &+= 1
        let generation = calendarSourceRefreshGeneration
        let taskID = UUID()
        let previousTask = calendarSourceRefreshTask
        previousTask?.cancel()

        let task = Task { [weak self] in
            if let previousTask {
                await previousTask.value
            }
            guard let self else { return }
            defer { finishCalendarSourceRefresh(taskID: taskID) }
            guard !Task.isCancelled,
                  isStarted,
                  generation == calendarSourceRefreshGeneration else { return }

            let refreshedEvents = await refreshEnabledCalendarSources(force: force)
            guard !Task.isCancelled,
                  isStarted,
                  generation == calendarSourceRefreshGeneration else { return }

            finishCalendarSourceRefresh(taskID: taskID)
            if resumesAfterWake {
                isCalendarSchedulingSuspendedForSleep = false
            }
            rescheduleAutomaticRecording(events: refreshedEvents)
        }
        calendarSourceRefreshTaskID = taskID
        calendarSourceRefreshTask = task
    }

    private func cancelCalendarSourceRefresh() {
        calendarSourceRefreshGeneration &+= 1
        calendarSourceRefreshTask?.cancel()
    }

    private func finishCalendarSourceRefresh(taskID: UUID) {
        guard calendarSourceRefreshTaskID == taskID else { return }
        calendarSourceRefreshTask = nil
        calendarSourceRefreshTaskID = nil
    }

    private func refreshEnabledCalendarSources(force: Bool = false) async -> [CalendarEvent] {
        let settings = AppSettings.shared
        guard shouldRefreshCalendarSources else { return [] }
        calendarAutoRecordingTask?.cancel()
        calendarAutoRecordingTask = nil

        await calendarSourceCoordinator.refreshEnabledSources(settings.enabledCalendarSources, force: force)
        return calendarSourceCoordinator.events(
            for: settings.enabledCalendarSources,
            requiringLoadedSources: true
        )
    }

    private func observeCalendarPowerEvents() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        let sleepObserver = notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.prepareCalendarSchedulingForSleep()
            }
        }
        let wakeObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshCalendarAfterWake()
            }
        }
        calendarPowerObservers = [sleepObserver, wakeObserver]
    }

    private func prepareCalendarSchedulingForSleep() {
        isCalendarSchedulingSuspendedForSleep = true
        calendarAutoRecordingTask?.cancel()
        calendarAutoRecordingTask = nil
        cancelCalendarSourceRefresh()
    }

    private func refreshCalendarAfterWake() {
        requestCalendarSourceRefresh(force: true, resumesAfterWake: true)
    }

    private func rescheduleCalendarNotifications() {
        calendarSchedulingTask?.cancel()
        let events = selectedUpcomingEvents
        calendarSchedulingTask = Task { [notificationService] in
            await notificationService.replaceCalendarNotifications(with: events)
        }
    }

    private var shouldRefreshCalendarSources: Bool {
        let settings = AppSettings.shared
        return (settings.meetingDetectionEnabled && settings.calendarEventMeetingNotificationsEnabled)
            || calendarAutoRecordingStore.hasSelections
    }

    private func calendarInputsDidChange() {
        rescheduleCalendarNotifications()
        rescheduleAutomaticRecording()
    }

    private func rescheduleAutomaticRecording(events providedEvents: [CalendarEvent]? = nil) {
        guard !isCalendarSchedulingSuspendedForSleep,
              calendarSourceRefreshTask == nil else { return }
        calendarAutoRecordingTask?.cancel()
        calendarAutoRecordingTask = nil

        let currentDate = now()
        let events = providedEvents ?? automaticRecordingEvents
        calendarAutoRecordingStore.synchronize(with: events, now: currentDate)
        let selections = calendarAutoRecordingStore.selections
        let dueEvents = CalendarAutoRecordingPlanner.dueEvents(
            events: events,
            selections: selections,
            now: currentDate
        )

        if let event = dueEvents.first {
            let dueEventIDs = Set(dueEvents.map(CalendarAutoRecordingEventID.init(event:)))
            calendarAutoRecordingStore.consume(dueEventIDs)
            guard !isRecording() else { return }
            onAutomaticRecording(event)
            return
        }

        guard let evaluationDate = CalendarAutoRecordingPlanner.nextEvaluationDate(
            events: events,
            selections: selections,
            now: currentDate
        ) else { return }

        let delay = evaluationDate.timeIntervalSince(currentDate)
        calendarAutoRecordingTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.rescheduleAutomaticRecording()
        }
    }

    // MARK: - ブラウザ会議ウィンドウ

    private func startWindowTitleScanning() {
        guard windowScanTimer == nil else { return }
        windowScanTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.scanWindowTitles()
            }
        }
        scanWindowTitles()
    }

    private func stopWindowTitleScanning() {
        windowScanTimer?.invalidate()
        windowScanTimer = nil
        windowScanTask?.cancel()
        windowScanTask = nil
        windowScanTaskID = nil
        windowDetectedBrowserContexts.removeAll()
    }

    private func scanWindowTitles() {
        guard windowScanTask == nil else { return }
        let taskID = UUID.v7()
        windowScanTaskID = taskID
        windowScanTask = Task { [weak self, meetingWindowDetectionWorker] in
            let detection = await meetingWindowDetectionWorker.detect()
            guard let self, windowScanTaskID == taskID else { return }
            windowScanTask = nil
            windowScanTaskID = nil
            guard !Task.isCancelled,
                  AppSettings.shared.automaticMeetingEndRecordingStopEnabled,
                  isRecordingLifecycleActive,
                  isActivelyRecording() else { return }
            applyWindowDetection(detection, observedAt: ContinuousClock.now)
        }
    }

    private func applyWindowDetection(
        _ detection: MeetingWindowDetection?,
        observedAt: ContinuousClock.Instant
    ) {
        windowDetectedBrowserContexts = detection?.browserContexts ?? []
        updateBrowserCorroboration(at: observedAt)
    }

    // MARK: - 会議音声プロセスによる開始通知と録音停止

    private func deliverStartNotification(for context: MeetingAudioContext) {
        let settings = AppSettings.shared
        guard settings.meetingDetectionEnabled,
              settings.microphoneMeetingNotificationsEnabled,
              !isRecording()
        else { return }

        let calendarEvent = recentCalendarEvent()
        let application = context.notificationApplication
        let meeting = DetectedMeeting(
            title: calendarEvent?.resolvedMeetingTitle ?? L10n.newMeeting,
            appName: application.name,
            bundleIdentifier: application.bundleIdentifier,
            calendarEvent: calendarEvent
        )

        Task { [notificationService] in
            await notificationService.deliverMicrophoneDetection(meeting)
        }
    }

    func recordingDidStart() {
        isRecordingLifecycleActive = true
        recordingActivityTracker.reset()
        reconcileMeetingAudioMonitoring()
    }

    func recordingDidStop() {
        isRecordingLifecycleActive = false
        recordingActivityTracker.reset()
        reconcileMeetingAudioMonitoring()
    }

    private func reconcileMeetingAudioMonitoring() {
        let settings = AppSettings.shared
        let shouldNotifyMeetingStart = settings.meetingDetectionEnabled
            && settings.microphoneMeetingNotificationsEnabled
        let policy = MeetingAudioMonitoringPolicy(
            startNotificationsEnabled: shouldNotifyMeetingStart,
            automaticStopEnabled: settings.automaticMeetingEndRecordingStopEnabled,
            isRecording: isRecordingLifecycleActive
        )

        if policy.shouldMonitorProcesses {
            startMeetingAudioMonitoring()
        } else {
            stopMeetingAudioMonitoring()
        }

        if policy.shouldScanBrowserWindows {
            armRecordingActivityIfNeeded()
            startWindowTitleScanning()
        } else {
            recordingActivityTracker.reset()
            stopWindowTitleScanning()
        }
    }

    private func startMeetingAudioMonitoring() {
        guard !isMeetingAudioMonitoringRunning else { return }
        isMeetingAudioMonitoringRunning = true
        meetingAudioMonitoringGeneration &+= 1
        let generation = meetingAudioMonitoringGeneration
        enqueueMeetingAudioMonitorCommand { [weak self, meetingAudioActivityMonitor] in
            await meetingAudioActivityMonitor.start(
                onChange: { [weak self] snapshot in
                    self?.handleMeetingAudioSnapshot(snapshot, generation: generation)
                },
                onQueryFailure: { [weak self] in
                    self?.handleMeetingAudioQueryFailure(generation: generation)
                }
            )
        }
    }

    private func stopMeetingAudioMonitoring() {
        guard isMeetingAudioMonitoringRunning else { return }
        isMeetingAudioMonitoringRunning = false
        meetingAudioMonitoringGeneration &+= 1
        meetingAudioSnapshot = nil
        recordingActivityTracker.reset()
        enqueueMeetingAudioMonitorCommand { [meetingAudioActivityMonitor] in
            await meetingAudioActivityMonitor.stop()
        }
    }

    private func enqueueMeetingAudioMonitorCommand(
        _ operation: @escaping @MainActor () async -> Void
    ) {
        let previousTask = meetingAudioMonitorCommandTask
        let commandID = UUID.v7()
        meetingAudioMonitorCommandID = commandID
        meetingAudioMonitorCommandTask = Task { [weak self] in
            await previousTask?.value
            await operation()
            guard self?.meetingAudioMonitorCommandID == commandID else { return }
            self?.meetingAudioMonitorCommandTask = nil
            self?.meetingAudioMonitorCommandID = nil
        }
    }

    private func handleMeetingAudioSnapshot(
        _ snapshot: MeetingAudioActivityMonitor.Snapshot,
        generation: UInt64
    ) {
        guard isMeetingAudioMonitoringRunning,
              generation == meetingAudioMonitoringGeneration else { return }
        meetingAudioSnapshot = snapshot
        let recordingIsActive = isRecordingLifecycleActive && isActivelyRecording()

        if let context = MeetingStartNotificationPlanner.context(
            for: snapshot,
            isRecording: isRecording()
        ) {
            deliverStartNotification(for: context)
        }

        if AppSettings.shared.automaticMeetingEndRecordingStopEnabled, recordingIsActive {
            armRecordingActivityIfNeeded(at: snapshot.observedAt)
            if recordingActivityTracker.shouldStop(after: snapshot) {
                onAutomaticRecordingStop()
            }
        } else if isRecordingLifecycleActive, !recordingIsActive {
            isRecordingLifecycleActive = false
            recordingActivityTracker.reset()
            reconcileMeetingAudioMonitoring()
        }
    }

    private func handleMeetingAudioQueryFailure(generation: UInt64) {
        guard isMeetingAudioMonitoringRunning,
              generation == meetingAudioMonitoringGeneration else { return }
        meetingAudioSnapshot = nil
        recordingActivityTracker.audioObservationFailed(at: ContinuousClock.now)
        guard isRecordingLifecycleActive, !isActivelyRecording() else { return }
        isRecordingLifecycleActive = false
        recordingActivityTracker.reset()
        reconcileMeetingAudioMonitoring()
    }

    private func armRecordingActivityIfNeeded(at instant: ContinuousClock.Instant = ContinuousClock.now) {
        guard !recordingActivityTracker.isArmed else { return }
        armRecordingActivity(at: instant)
    }

    private func armRecordingActivity(at instant: ContinuousClock.Instant) {
        recordingActivityTracker.recordingDidStart(at: instant)
    }

    private func updateBrowserCorroboration(at instant: ContinuousClock.Instant) {
        guard AppSettings.shared.automaticMeetingEndRecordingStopEnabled,
              isRecordingLifecycleActive,
              isActivelyRecording() else { return }
        recordingActivityTracker.observeBrowserCorroboration(
            browserContexts: windowDetectedBrowserContexts,
            observedAudioContexts: meetingAudioSnapshot?.observedContexts ?? [],
            at: instant
        )
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
        calendarSourceCoordinator.events(for: AppSettings.shared.enabledCalendarSources)
    }

    private var automaticRecordingEvents: [CalendarEvent] {
        calendarSourceCoordinator.events(
            for: AppSettings.shared.enabledCalendarSources,
            requiringLoadedSources: true
        )
    }
}
