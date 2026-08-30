/// 逐次認識イベントを正本 transcript として保存するかを指定する。
enum TranscriptPersistencePolicy {
    case streaming
    case deferred

    var persistsStreamingSegments: Bool {
        self == .streaming
    }
}
