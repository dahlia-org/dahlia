import Foundation
import os

/// Recording callbacks set this synchronously before any background launch can be considered.
enum AgentBackgroundActivity {
    private static let recording = OSAllocatedUnfairLock(initialState: false)
    static var isRecording: Bool { recording.withLock { $0 } }
    static func setRecording(_ active: Bool) { recording.withLock { $0 = active } }
}
