import Foundation
@preconcurrency import UserNotifications

private let meetingNotificationPayloadKey = "dahliaDetectedMeeting"

/// ミーティング通知を選択された表示形式で提示し、通知アクションをアプリ内の録音処理へ中継する。
@MainActor
final class MeetingNotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = MeetingNotificationService()

    private static let microphoneCategoryIdentifier = "dahlia.meeting.microphone"
    private static let calendarCategoryIdentifier = "dahlia.meeting.calendar"
    private static let calendarJoinCategoryIdentifier = "dahlia.meeting.calendar.join"
    private static let startRecordingActionIdentifier = "dahlia.meeting.start-recording"
    private static let joinAndStartRecordingActionIdentifier = "dahlia.meeting.join-and-start-recording"
    private static let calendarRequestPrefix = "dahlia.meeting.calendar.request."
    private static let microphoneRequestPrefix = "dahlia.meeting.microphone.request."
    private static let threadIdentifier = "dahlia.meeting"
    /// システムの保留通知数には上限があるため、直近の予定を優先して余裕を残す。
    private static let maximumScheduledCalendarNotifications = 50

    private let notificationCenter: UNUserNotificationCenter
    private let popupPresenter = MeetingNotificationPopupPresenter()
    private let calendarPopupScheduler = MeetingCalendarPopupScheduler()
    private var onOpenMeeting: (DetectedMeeting) -> Void = { _ in }
    private var onStartRecording: (DetectedMeeting) -> Void = { _ in }
    private var onJoinMeeting: (DetectedMeeting) -> Void = { _ in }
    private var onJoinAndStartRecording: (DetectedMeeting) -> Void = { _ in }
    private var pendingResponses: [(actionIdentifier: String, meeting: DetectedMeeting)] = []
    private var callbacksAreConfigured = false
    private var calendarOperationTask: Task<Void, Never>?
    private var notificationAuthorizationTask: Task<Bool, Never>?
    private var activePresentation: MeetingNotificationPresentation?
    private var deliveredCalendarIdentifiers = Set<String>()

    private init(notificationCenter: UNUserNotificationCenter = .current()) {
        self.notificationCenter = notificationCenter
        super.init()
    }

    /// Apple の要件に従い、AppDelegate の起動完了コールバック内で呼び出す。
    func install() {
        notificationCenter.delegate = self
        registerCategories()
    }

    func refreshCategories() {
        registerCategories()
    }

    func configure(
        onOpenMeeting: @escaping (DetectedMeeting) -> Void,
        onStartRecording: @escaping (DetectedMeeting) -> Void,
        onJoinMeeting: @escaping (DetectedMeeting) -> Void,
        onJoinAndStartRecording: @escaping (DetectedMeeting) -> Void
    ) {
        self.onOpenMeeting = onOpenMeeting
        self.onStartRecording = onStartRecording
        self.onJoinMeeting = onJoinMeeting
        self.onJoinAndStartRecording = onJoinAndStartRecording
        callbacksAreConfigured = true

        let responses = pendingResponses
        pendingResponses.removeAll()
        for response in responses {
            perform(actionIdentifier: response.actionIdentifier, meeting: response.meeting)
        }
    }

    func requestAuthorizationIfNeeded() async -> Bool {
        if let notificationAuthorizationTask {
            return await notificationAuthorizationTask.value
        }

        let task = Task { @MainActor [notificationCenter] in
            let settings = await notificationCenter.notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                return true
            case .notDetermined:
                do {
                    return try await notificationCenter.requestAuthorization(options: [.alert, .sound])
                } catch {
                    ErrorReportingService.capture(error, context: ["source": "meetingNotificationAuthorization"])
                    return false
                }
            case .denied:
                return false
            @unknown default:
                return false
            }
        }
        notificationAuthorizationTask = task
        let isAuthorized = await task.value
        notificationAuthorizationTask = nil
        return isAuthorized
    }

    func deliverMicrophoneDetection(_ meeting: DetectedMeeting) async -> Bool {
        let settings = AppSettings.shared
        guard settings.meetingDetectionEnabled,
              settings.microphoneMeetingNotificationsEnabled
        else { return false }

        let presentation = settings.meetingNotificationPresentation
        await synchronizePresentation(presentation)
        let title = meeting.calendarEvent == nil ? L10n.meetingDetected : meeting.title
        let body = L10n.meetingDetectedSubtitle(meeting.appName)

        if presentation == .prominentPopup {
            popupPresenter.present(
                MeetingNotificationPopup(
                    id: Self.microphoneRequestPrefix + meeting.id.uuidString,
                    meeting: meeting,
                    title: title,
                    subtitle: meeting.calendarEvent?.calendarName,
                    body: body,
                    isCalendarNotification: false
                ),
                onAction: performPopupAction
            )
            return true
        }

        guard await requestAuthorizationIfNeeded() else { return false }

        do {
            let content = try notificationContent(
                for: meeting,
                title: title,
                body: body,
                categoryIdentifier: Self.microphoneCategoryIdentifier
            )
            let request = UNNotificationRequest(
                identifier: Self.microphoneRequestPrefix + meeting.id.uuidString,
                content: content,
                trigger: nil
            )
            try await notificationCenter.add(request)
            return true
        } catch {
            ErrorReportingService.capture(error, context: ["source": "microphoneMeetingNotification"])
            return false
        }
    }

    func replaceCalendarNotifications(with events: [CalendarEvent]) async {
        await enqueueCalendarOperation { [weak self] in
            await self?.performReplaceCalendarNotifications(with: events)
        }
    }

    func cancelCalendarNotifications() async {
        await enqueueCalendarOperation { [weak self] in
            await self?.removeCalendarNotifications(includeDelivered: true)
        }
    }

    private func performReplaceCalendarNotifications(with events: [CalendarEvent]) async {
        let settings = AppSettings.shared
        let presentation = settings.meetingNotificationPresentation
        await synchronizePresentation(presentation)
        guard settings.meetingDetectionEnabled else {
            calendarPopupScheduler.cancel()
            popupPresenter.removeAll()
            await removeSystemMeetingNotifications()
            return
        }
        if !settings.microphoneMeetingNotificationsEnabled {
            popupPresenter.removeMicrophoneNotifications()
            await removeSystemMicrophoneNotifications()
        }
        guard settings.calendarEventMeetingNotificationsEnabled else {
            await removeCalendarNotifications(includeDelivered: true)
            return
        }

        let now = Date.now
        let schedule = calendarSchedule(for: events, filter: settings.calendarEventFilter, now: now)
        if presentation == .prominentPopup {
            await removeSystemCalendarNotifications(includeDelivered: true)
            replaceCalendarPopupNotifications(with: schedule)
            return
        }

        calendarPopupScheduler.cancel()
        popupPresenter.removeCalendarNotifications()
        let isAuthorized = await requestAuthorizationIfNeeded()
        guard !Task.isCancelled else { return }
        guard isAuthorized else {
            await removeCalendarNotifications(includeDelivered: false)
            return
        }

        let scheduledIdentifiers = Set(
            schedule.map { Self.calendarNotificationIdentifier(for: $0.event) }
        )

        let pendingRequests = await notificationCenter.pendingNotificationRequests()
        guard !Task.isCancelled else { return }
        let pendingIdentifiers = pendingRequests
            .map(\.identifier)
            .filter(Self.isCalendarNotificationIdentifier)
        if !pendingIdentifiers.isEmpty {
            notificationCenter.removePendingNotificationRequests(withIdentifiers: pendingIdentifiers)
        }

        let deliveredNotifications = await notificationCenter.deliveredNotifications()
        guard !Task.isCancelled else { return }
        let deliveredIdentifiers = Set(
            deliveredNotifications
                .map(\.request.identifier)
                .filter(Self.isCalendarNotificationIdentifier)
        )
        deliveredCalendarIdentifiers.formUnion(deliveredIdentifiers)
        let staleDeliveredIdentifiers = CalendarMeetingNotificationPlanner.staleDeliveredIdentifiers(
            from: deliveredIdentifiers,
            scheduledIdentifiers: scheduledIdentifiers
        )
        notificationCenter.removeDeliveredNotifications(withIdentifiers: staleDeliveredIdentifiers)

        registerCategories()

        for (event, notificationDate) in schedule {
            guard !Task.isCancelled else { return }
            let identifier = Self.calendarNotificationIdentifier(for: event)
            guard !deliveredCalendarIdentifiers.contains(identifier) else { continue }

            do {
                try await addCalendarNotification(
                    for: event,
                    at: notificationDate,
                    identifier: identifier
                )
            } catch {
                ErrorReportingService.capture(
                    error,
                    context: [
                        "source": "calendarMeetingNotification",
                        "platform": event.platform,
                        "platformId": event.platformId,
                    ]
                )
            }
        }
    }

    private func removeCalendarNotifications(includeDelivered: Bool) async {
        calendarPopupScheduler.cancel()
        popupPresenter.removeCalendarNotifications()
        await removeSystemCalendarNotifications(includeDelivered: includeDelivered)
    }

    private func removeSystemCalendarNotifications(includeDelivered: Bool) async {
        let pendingRequests = await notificationCenter.pendingNotificationRequests()
        guard !Task.isCancelled else { return }
        let pendingIdentifiers = pendingRequests
            .map(\.identifier)
            .filter(Self.isCalendarNotificationIdentifier)
        if !pendingIdentifiers.isEmpty {
            notificationCenter.removePendingNotificationRequests(withIdentifiers: pendingIdentifiers)
        }

        guard includeDelivered else { return }
        let deliveredNotifications = await notificationCenter.deliveredNotifications()
        guard !Task.isCancelled else { return }
        let deliveredIdentifiers = deliveredNotifications
            .map(\.request.identifier)
            .filter(Self.isCalendarNotificationIdentifier)
        if !deliveredIdentifiers.isEmpty {
            notificationCenter.removeDeliveredNotifications(withIdentifiers: deliveredIdentifiers)
        }
    }

    private func removeSystemMeetingNotifications() async {
        let pendingRequests = await notificationCenter.pendingNotificationRequests()
        let pendingIdentifiers = pendingRequests
            .map(\.identifier)
            .filter(Self.isMeetingNotificationIdentifier)
        if !pendingIdentifiers.isEmpty {
            notificationCenter.removePendingNotificationRequests(withIdentifiers: pendingIdentifiers)
        }

        let deliveredNotifications = await notificationCenter.deliveredNotifications()
        let deliveredIdentifiers = deliveredNotifications
            .map(\.request.identifier)
            .filter(Self.isMeetingNotificationIdentifier)
        deliveredCalendarIdentifiers.formUnion(
            deliveredIdentifiers.filter(Self.isCalendarNotificationIdentifier)
        )
        if !deliveredIdentifiers.isEmpty {
            notificationCenter.removeDeliveredNotifications(withIdentifiers: deliveredIdentifiers)
        }
    }

    private func removeSystemMicrophoneNotifications() async {
        let pendingRequests = await notificationCenter.pendingNotificationRequests()
        let pendingIdentifiers = pendingRequests
            .map(\.identifier)
            .filter(Self.isMicrophoneNotificationIdentifier)
        if !pendingIdentifiers.isEmpty {
            notificationCenter.removePendingNotificationRequests(withIdentifiers: pendingIdentifiers)
        }

        let deliveredNotifications = await notificationCenter.deliveredNotifications()
        let deliveredIdentifiers = deliveredNotifications
            .map(\.request.identifier)
            .filter(Self.isMicrophoneNotificationIdentifier)
        if !deliveredIdentifiers.isEmpty {
            notificationCenter.removeDeliveredNotifications(withIdentifiers: deliveredIdentifiers)
        }
    }

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let actionIdentifier = response.actionIdentifier
        let payload = response.notification.request.content.userInfo[meetingNotificationPayloadKey] as? String
        await handleResponse(actionIdentifier: actionIdentifier, payload: payload)
    }

    private func enqueueCalendarOperation(
        _ operation: @escaping @MainActor () async -> Void
    ) async {
        let previousTask = calendarOperationTask
        previousTask?.cancel()

        let nextTask = Task { @MainActor in
            await previousTask?.value
            guard !Task.isCancelled else { return }
            await operation()
        }
        calendarOperationTask = nextTask
        await nextTask.value
    }

    private func calendarSchedule(
        for events: [CalendarEvent],
        filter: CalendarEventFilter,
        now: Date
    ) -> [(event: CalendarEvent, notificationDate: Date)] {
        CalendarMeetingNotificationPlanner.schedule(
            for: events,
            filter: filter,
            now: now,
            limit: Self.maximumScheduledCalendarNotifications
        )
    }

    private func replaceCalendarPopupNotifications(
        with schedule: [(event: CalendarEvent, notificationDate: Date)]
    ) {
        let scheduledIdentifiers = Set(schedule.map { Self.calendarNotificationIdentifier(for: $0.event) })
        popupPresenter.retainCalendarNotifications(withIdentifiers: scheduledIdentifiers)
        calendarPopupScheduler.replace(
            with: schedule,
            identifierForEvent: Self.calendarNotificationIdentifier,
            onPresent: { [weak self] event, identifier in
                self?.presentCalendarPopup(for: event, identifier: identifier)
            }
        )
    }

    private func presentCalendarPopup(for event: CalendarEvent, identifier: String) {
        guard deliveredCalendarIdentifiers.insert(identifier).inserted else { return }
        let meeting = DetectedMeeting(
            title: event.resolvedMeetingTitle,
            appName: L10n.calendar,
            bundleIdentifier: event.platform,
            calendarEvent: event
        )
        popupPresenter.present(
            MeetingNotificationPopup(
                id: identifier,
                meeting: meeting,
                title: meeting.title,
                subtitle: event.calendarName,
                body: L10n.calendarEventStartsInOneMinute,
                isCalendarNotification: true
            ),
            onAction: performPopupAction
        )
    }

    private func synchronizePresentation(_ presentation: MeetingNotificationPresentation) async {
        guard activePresentation != presentation else { return }
        activePresentation = presentation
        calendarPopupScheduler.cancel()
        popupPresenter.removeAll()
        if presentation == .prominentPopup {
            await removeSystemMeetingNotifications()
        }
    }

    private func registerCategories() {
        let startRecordingAction = UNNotificationAction(
            identifier: Self.startRecordingActionIdentifier,
            title: L10n.startRecording,
            options: [.foreground]
        )
        let joinAndStartRecordingAction = UNNotificationAction(
            identifier: Self.joinAndStartRecordingActionIdentifier,
            title: L10n.joinAndStartRecording,
            options: [.foreground]
        )

        let microphoneCategory = UNNotificationCategory(
            identifier: Self.microphoneCategoryIdentifier,
            actions: [startRecordingAction],
            intentIdentifiers: [],
            options: []
        )
        let calendarCategory = UNNotificationCategory(
            identifier: Self.calendarCategoryIdentifier,
            actions: [startRecordingAction],
            intentIdentifiers: [],
            options: []
        )
        let calendarJoinCategory = UNNotificationCategory(
            identifier: Self.calendarJoinCategoryIdentifier,
            actions: [joinAndStartRecordingAction],
            intentIdentifiers: [],
            options: []
        )

        notificationCenter.setNotificationCategories([
            microphoneCategory,
            calendarCategory,
            calendarJoinCategory,
        ])
    }

    private func notificationContent(
        for meeting: DetectedMeeting,
        title: String,
        subtitle: String? = nil,
        body: String,
        categoryIdentifier: String
    ) throws -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle {
            content.subtitle = subtitle
        }
        content.body = body
        content.categoryIdentifier = categoryIdentifier
        content.sound = .default
        content.threadIdentifier = Self.threadIdentifier
        content.userInfo = try [meetingNotificationPayloadKey: Self.payload(for: meeting)]
        return content
    }

    private func addCalendarNotification(
        for event: CalendarEvent,
        at notificationDate: Date,
        identifier: String
    ) async throws {
        let meeting = DetectedMeeting(
            title: event.resolvedMeetingTitle,
            appName: L10n.calendar,
            bundleIdentifier: event.platform,
            calendarEvent: event
        )
        let categoryIdentifier = event.conferenceURI == nil
            ? Self.calendarCategoryIdentifier
            : Self.calendarJoinCategoryIdentifier
        let content = try notificationContent(
            for: meeting,
            title: meeting.title,
            subtitle: event.calendarName,
            body: L10n.calendarEventStartsInOneMinute,
            categoryIdentifier: categoryIdentifier
        )
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(1, notificationDate.timeIntervalSinceNow),
            repeats: false
        )
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: trigger
        )
        try await notificationCenter.add(request)
    }

    private func handleResponse(actionIdentifier: String, payload: String?) {
        guard actionIdentifier != UNNotificationDismissActionIdentifier,
              let payload,
              let meeting = Self.meeting(from: payload)
        else { return }

        guard callbacksAreConfigured else {
            pendingResponses.append((actionIdentifier, meeting))
            return
        }

        perform(actionIdentifier: actionIdentifier, meeting: meeting)
    }

    private func perform(actionIdentifier: String, meeting: DetectedMeeting) {
        switch actionIdentifier {
        case UNNotificationDefaultActionIdentifier:
            onOpenMeeting(meeting)
        case Self.startRecordingActionIdentifier:
            onStartRecording(meeting)
        case Self.joinAndStartRecordingActionIdentifier:
            onJoinAndStartRecording(meeting)
        default:
            break
        }
    }

    private func performPopupAction(
        _ popup: MeetingNotificationPopup,
        _ action: MeetingNotificationPopup.Action
    ) {
        action.perform(
            for: popup.meeting,
            onStartRecording: onStartRecording,
            onJoinMeeting: onJoinMeeting,
            onJoinAndStartRecording: onJoinAndStartRecording
        )
    }

    private static func calendarNotificationIdentifier(for event: CalendarEvent) -> String {
        let timestamp = Int(event.startDate.timeIntervalSince1970)
        return "\(calendarRequestPrefix)\(event.platform).\(event.platformId).\(timestamp)"
    }

    private static func isCalendarNotificationIdentifier(_ identifier: String) -> Bool {
        identifier.hasPrefix(calendarRequestPrefix)
    }

    private static func isMicrophoneNotificationIdentifier(_ identifier: String) -> Bool {
        identifier.hasPrefix(microphoneRequestPrefix)
    }

    private static func isMeetingNotificationIdentifier(_ identifier: String) -> Bool {
        isCalendarNotificationIdentifier(identifier) || isMicrophoneNotificationIdentifier(identifier)
    }

    private static func payload(for meeting: DetectedMeeting) throws -> String {
        try JSONEncoder().encode(meeting).base64EncodedString()
    }

    private static func meeting(from payload: String) -> DetectedMeeting? {
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONDecoder().decode(DetectedMeeting.self, from: data)
    }
}
