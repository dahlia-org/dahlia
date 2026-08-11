struct MeetingAudioMonitoringPolicy {
    let shouldMonitorProcesses: Bool
    let shouldScanBrowserWindows: Bool

    init(
        startNotificationsEnabled: Bool,
        automaticStopEnabled: Bool,
        isRecording: Bool
    ) {
        shouldScanBrowserWindows = automaticStopEnabled && isRecording
        shouldMonitorProcesses = (startNotificationsEnabled && !isRecording) || shouldScanBrowserWindows
    }
}
