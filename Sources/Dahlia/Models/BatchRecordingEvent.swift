import Foundation

enum BatchRecordingEvent {
    case finalizationDelayed(source: RecordingAudioSource)
    case finalizationRecovered(source: RecordingAudioSource)
    case failed(source: RecordingAudioSource, error: RecordingAudioStoreError)
}
