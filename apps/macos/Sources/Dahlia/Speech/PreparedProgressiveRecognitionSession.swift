@preconcurrency import AVFoundation

/// recognizer が要求する形式と、開始前のrecognition sessionをまとめたprepare結果。
struct PreparedProgressiveRecognitionSession {
    let analyzerFormat: AVAudioFormat
    let session: any ProgressiveRecognitionSession
}
