import AppKit
import Combine
import CoreAudio
import CoreGraphics
import Foundation
import SwiftUI

/// マイク使用検出 + ミーティングアプリ検出 + ウィンドウタイトル解析の 3 層で
/// ビデオ会議を検出し、最前面ポップアップで文字起こし開始を促す。
@MainActor
final class MeetingDetectionService: ObservableObject {

    // MARK: - Published State

    @Published var detectedMeeting: DetectedMeeting?

    // MARK: - External Dependencies

    var isRecording: () -> Bool = { false }
    var onOpenMeeting: (DetectedMeeting) -> Void = { _ in }
    var onStartTranscription: (DetectedMeeting) -> Void = { _ in }
    var onManageNotifications: () -> Void = {}

    // MARK: - Constants

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

    private static let meetCodeRegex = try! NSRegularExpression(pattern: "[a-z]{3}-[a-z]{4}-[a-z]{3}")

    private static let browserNames: Set = [
        "Google Chrome", "Safari", "Microsoft Edge", "Arc", "Firefox",
        "Brave Browser", "Chromium", "Vivaldi", "Opera",
    ]

    // MARK: - Private State

    /// 監視中のデバイス ID とリスナーブロックのペア。除去時に同じ参照を渡す必要がある。
    private var deviceListeners: [(id: AudioDeviceID, block: AudioObjectPropertyListenerBlock)] = []
    /// デバイスリスト変更リスナーブロック。
    private var deviceListChangeBlock: AudioObjectPropertyListenerBlock?
    @Published private var isMicrophoneInUse = false
    @Published private var activeMeetingAppName: String?
    @Published private var windowDetectedMeetingName: String?
    private var suppressed = false
    private var cancellables = Set<AnyCancellable>()
    private var windowScanTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var autoDismissTask: Task<Void, Never>?
    private var panel: NSPanel?
    private var panelCloseObserver: NSObjectProtocol?
    /// CoreAudio リスナーコールバック用の共有キュー。
    private let micMonitorQueue = DispatchQueue(label: "com.dahlia.micMonitor")
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    // MARK: - Lifecycle

    func start() {
        guard AppSettings.shared.meetingDetectionEnabled else { return }
        startMicrophoneMonitoring()
        startAppMonitoring()
        startWindowTitleScanning()
        startCombinedDetection()
    }

    func stop() {
        cancellables.removeAll()
        windowScanTimer?.invalidate()
        windowScanTimer = nil
        removeAllDeviceListeners()
        removeDeviceListChangeListener()
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        autoDismissTask?.cancel()
        closePanel()
        detectedMeeting = nil
    }

    func dismiss() {
        suppressed = true
        autoDismissTask?.cancel()
        closePanel()
        detectedMeeting = nil
    }

    // MARK: - Layer 1: マイク使用状態の監視

    private func startMicrophoneMonitoring() {
        registerListenersForAllInputDevices()

        // USB マイク抜き差し等でリスナーを再登録
        var address = Self.globalAddress(kAudioHardwarePropertyDevices)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                self?.registerListenersForAllInputDevices()
            }
        }
        deviceListChangeBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            micMonitorQueue,
            block
        )
    }

    private func registerListenersForAllInputDevices() {
        removeAllDeviceListeners()

        let inputDevices = Self.getAllInputDevices()
        for deviceID in inputDevices {
            var address = Self.globalAddress(kAudioDevicePropertyDeviceIsRunningSomewhere)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor in
                    self?.recheckAllDevices()
                }
            }
            AudioObjectAddPropertyListenerBlock(deviceID, &address, micMonitorQueue, block)
            deviceListeners.append((id: deviceID, block: block))
        }

        recheckAllDevices()
    }

    /// 全入力デバイスの状態を再チェックし、いずれかが使用中なら true にする。
    private func recheckAllDevices() {
        let running = Self.getAllInputDevices().contains { Self.isDeviceRunningSomewhere($0) }
        if isMicrophoneInUse != running {
            isMicrophoneInUse = running
        }
        if !running {
            suppressed = false
        }
    }

    private func removeAllDeviceListeners() {
        for listener in deviceListeners {
            var address = Self.globalAddress(kAudioDevicePropertyDeviceIsRunningSomewhere)
            AudioObjectRemovePropertyListenerBlock(listener.id, &address, micMonitorQueue, listener.block)
        }
        deviceListeners.removeAll()
    }

    private func removeDeviceListChangeListener() {
        guard let block = deviceListChangeBlock else { return }
        var address = Self.globalAddress(kAudioHardwarePropertyDevices)
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address, micMonitorQueue, block
        )
        deviceListChangeBlock = nil
    }

    // MARK: - Layer 2: ミーティングアプリの起動監視

    private func startAppMonitoring() {
        let nc = NSWorkspace.shared.notificationCenter

        let launchObserver = nc.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.checkRunningMeetingApps() }
        }

        let terminateObserver = nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.checkRunningMeetingApps() }
        }

        workspaceObservers = [launchObserver, terminateObserver]
        checkRunningMeetingApps()
    }

    private func checkRunningMeetingApps() {
        let name = NSWorkspace.shared.runningApplications.first { app in
            guard let bid = app.bundleIdentifier else { return false }
            return Self.meetingBundleIDs.contains(bid)
        }?.localizedName
        if activeMeetingAppName != name {
            activeMeetingAppName = name
        }
    }

    // MARK: - Layer 3: ウィンドウタイトル解析

    private func startWindowTitleScanning() {
        windowScanTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.scanWindowTitles()
            }
        }
        scanWindowTitles()
    }

    private func scanWindowTitles() {
        // 検出不要な状態ではスキャンを省略
        guard !suppressed, detectedMeeting == nil, !isRecording() else { return }
        let detected = Self.detectMeetingFromWindowTitles()
        if windowDetectedMeetingName != detected {
            windowDetectedMeetingName = detected
        }
    }

    // MARK: - 3層統合検出

    private func startCombinedDetection() {
        Publishers.CombineLatest3(
            $isMicrophoneInUse.removeDuplicates(),
            $activeMeetingAppName.removeDuplicates(),
            $windowDetectedMeetingName.removeDuplicates()
        )
        .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
        .sink { [weak self] micActive, meetingApp, windowMeeting in
            self?.evaluateDetection(
                micActive: micActive,
                meetingApp: meetingApp,
                windowMeeting: windowMeeting
            )
        }
        .store(in: &cancellables)
    }

    private func evaluateDetection(micActive: Bool, meetingApp: String?, windowMeeting: String?) {
        guard AppSettings.shared.meetingDetectionEnabled,
              !isRecording(),
              !suppressed,
              detectedMeeting == nil,
              micActive,
              meetingApp != nil || windowMeeting != nil
        else { return }

        let appName = windowMeeting ?? meetingApp ?? ""
        let bundleID = NSWorkspace.shared.runningApplications.first {
            $0.localizedName == appName
        }?.bundleIdentifier ?? "unknown"

        showMeetingPopup(appName: appName, bundleIdentifier: bundleID)
    }

    // MARK: - CoreAudio Helpers

    private nonisolated static func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private nonisolated static func getAllInputDevices() -> [AudioDeviceID] {
        var address = globalAddress(kAudioHardwarePropertyDevices)
        var propSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &propSize
        ) == noErr else { return [] }

        let count = Int(propSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &propSize, &devices
        ) == noErr else { return [] }

        return devices.filter { device in
            var inputAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            AudioObjectGetPropertyDataSize(device, &inputAddr, 0, nil, &streamSize)
            return streamSize > 0
        }
    }

    private nonisolated static func isDeviceRunningSomewhere(_ deviceID: AudioDeviceID) -> Bool {
        var address = globalAddress(kAudioDevicePropertyDeviceIsRunningSomewhere)
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &isRunning) == noErr else {
            return false
        }
        return isRunning != 0
    }

    // MARK: - Window Title Helpers

    private static func detectMeetingFromWindowTitles() -> String? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        for w in windows {
            guard let owner = w[kCGWindowOwnerName as String] as? String,
                  let title = w[kCGWindowName as String] as? String,
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

    // MARK: - Floating Panel

    private func showMeetingPopup(appName: String, bundleIdentifier: String) {
        let calendarEvent = recentCalendarEvent()
        let meeting = DetectedMeeting(
            title: meetingTitle(for: calendarEvent),
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            calendarEvent: calendarEvent
        )
        detectedMeeting = meeting

        closePanel()

        let popupView = MeetingDetectionPopupView(
            meeting: meeting,
            onOpen: { [weak self] in
                self?.onOpenMeeting(meeting)
                self?.dismiss()
            },
            onStart: { [weak self] in
                self?.onStartTranscription(meeting)
                self?.dismiss()
            },
            onManageNotifications: { [weak self] in
                self?.onManageNotifications()
                self?.dismiss()
            },
            onDismiss: { [weak self] in
                self?.dismiss()
            }
        )

        let hostingView = NSHostingView(rootView: popupView)
        hostingView.setFrameSize(hostingView.fittingSize)

        let panelRect = panelFrame(for: hostingView.fittingSize)
        let newPanel = NSPanel(
            contentRect: panelRect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        newPanel.isFloatingPanel = true
        newPanel.level = .floating
        newPanel.titlebarAppearsTransparent = true
        newPanel.titleVisibility = .hidden
        newPanel.isMovableByWindowBackground = true
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = false
        newPanel.contentView = hostingView
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.animationBehavior = .utilityWindow

        panelCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: newPanel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.detectedMeeting = nil
                self?.suppressed = true
            }
        }

        newPanel.alphaValue = 0
        newPanel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            newPanel.animator().alphaValue = 1
        }

        panel = newPanel

        autoDismissTask?.cancel()
        autoDismissTask = Task {
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }

    private func closePanel() {
        if let observer = panelCloseObserver {
            NotificationCenter.default.removeObserver(observer)
            panelCloseObserver = nil
        }
        guard let existingPanel = panel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            existingPanel.animator().alphaValue = 0
        } completionHandler: { [existingPanel] in
            Task { @MainActor in
                existingPanel.close()
            }
        }
        panel = nil
    }

    private func panelFrame(for size: NSSize) -> NSRect {
        guard let screen = NSScreen.main else {
            return NSRect(origin: .zero, size: size)
        }
        let visibleFrame = screen.visibleFrame
        let x = visibleFrame.midX - size.width / 2
        let y = visibleFrame.maxY - size.height - 12
        return NSRect(x: x, y: y, width: size.width, height: size.height)
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

    private func meetingTitle(for calendarEvent: CalendarEvent?) -> String {
        let trimmed = calendarEvent?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? L10n.newMeeting : trimmed
    }
}
