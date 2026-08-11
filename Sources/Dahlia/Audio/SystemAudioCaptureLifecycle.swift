/// Generation-based lifecycle state for ScreenCaptureKit system-audio capture.
///
/// The actor owner uses this value to reject stale start and delegate completions.
struct SystemAudioCaptureLifecycle: Equatable, Sendable {
    enum StopRequest: Equatable, Sendable {
        case begin(generation: UInt64)
        case wait(generation: UInt64)
    }

    private(set) var activeGeneration: UInt64?
    private(set) var isStopRequested = false
    private(set) var isCompletionInProgress = false
    private var nextGeneration: UInt64 = 0

    mutating func beginStart() -> UInt64? {
        guard activeGeneration == nil else { return nil }
        nextGeneration &+= 1
        activeGeneration = nextGeneration
        isStopRequested = false
        isCompletionInProgress = false
        return nextGeneration
    }

    func canContinueStart(generation: UInt64) -> Bool {
        activeGeneration == generation && !isStopRequested && !isCompletionInProgress
    }

    mutating func requestStop() -> StopRequest? {
        guard let activeGeneration else { return nil }
        if isCompletionInProgress {
            return .wait(generation: activeGeneration)
        }
        isStopRequested = true
        isCompletionInProgress = true
        return .begin(generation: activeGeneration)
    }

    /// Claims completion ownership for an unexpected delegate callback.
    /// Returns whether the callback should be reported to the session owner.
    mutating func beginDelegateCompletion(generation: UInt64) -> Bool? {
        guard activeGeneration == generation, !isCompletionInProgress else { return nil }
        isCompletionInProgress = true
        return !isStopRequested
    }

    mutating func abandonStart(generation: UInt64) {
        guard activeGeneration == generation, !isCompletionInProgress else { return }
        clearActiveCapture()
    }

    mutating func finishCompletion(generation: UInt64) {
        guard activeGeneration == generation, isCompletionInProgress else { return }
        clearActiveCapture()
    }

    private mutating func clearActiveCapture() {
        activeGeneration = nil
        isStopRequested = false
        isCompletionInProgress = false
    }
}
