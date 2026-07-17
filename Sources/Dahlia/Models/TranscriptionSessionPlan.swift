// swiftformat:disable:next redundantSendable
/// 録音セッションで有効にする文字起こし機能の組み合わせ。
struct TranscriptionSessionPlan: Equatable {
    let finalMode: TranscriptionMode
    var liveSubtitlesEnabled: Bool
    let retainBatchAudio: Bool

    /// 正本文字起こし、またはライブ字幕のために逐次認識が必要か。
    var requiresLiveRecognition: Bool {
        finalMode == .realtime || liveSubtitlesEnabled
    }

    /// バッチ文字起こし用の音声を録音するか。
    var recordsBatchAudio: Bool {
        finalMode == .batch
    }

    /// 逐次認識の結果を正本文字起こしとして永続化するか。
    var persistsRealtimeTranscript: Bool {
        finalMode == .realtime
    }

    /// 有効な各音源に対して生成する逐次認識器数。
    /// realtime + live でも常に1つだけとする。
    var liveRecognizerCountPerSource: Int {
        requiresLiveRecognition ? 1 : 0
    }

    var batchRecorderCountPerSource: Int {
        recordsBatchAudio ? 1 : 0
    }
}
