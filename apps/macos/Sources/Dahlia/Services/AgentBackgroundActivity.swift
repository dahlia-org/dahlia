import Foundation
import os

/// The app observes recording preparation, capture and finalization synchronously.
enum AgentBackgroundActivity {
    private static let recording = OSAllocatedUnfairLock(initialState: false)
    static var isRecording: Bool { recording.withLock { $0 } }
    static func setRecording(_ active: Bool) { recording.withLock { $0 = active } }
}
