/// 同時に開始した会議コンテキストを、安定した優先順位で一件の通知候補へ集約する。
enum MeetingStartNotificationPlanner {
    static func context(
        for snapshot: MeetingAudioActivityMonitor.Snapshot,
        isRecording: Bool
    ) -> MeetingAudioContext? {
        guard !snapshot.isInitial, !isRecording else { return nil }
        return MeetingAudioContext.allCases.first { snapshot.startedContexts.contains($0) }
    }
}
