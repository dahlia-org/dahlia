@preconcurrency import AVFoundation
import CoreMedia

/// 物理 capture から生成された、セッション時刻付きの不変オーディオチャンク。
/// 同じインスタンスを batch writer と progressive recognizer へ fan-out する。
struct CapturedAudioChunk {
    let source: RecordingAudioSource
    let buffer: AVAudioPCMBuffer
    let sessionRelativeStartTime: CMTime

    var sessionRelativeStartSeconds: TimeInterval {
        sessionRelativeStartTime.seconds
    }
}
