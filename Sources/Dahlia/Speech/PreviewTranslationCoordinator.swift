import Foundation

actor PreviewTranslationCoordinator {
    typealias TranslationHandler = @Sendable (TranscriptSegment) async -> String?
    typealias ApplyTranslationHandler = @MainActor @Sendable (UUID, String?) async -> Void
    typealias SleepHandler = @Sendable (Duration) async -> Void

    private let debounceDuration: Duration
    private let minimumCharacterDelta: Int
    private let sleep: SleepHandler
    private let translate: TranslationHandler

    private var translationTasks: [UUID: Task<Void, Never>] = [:]
    private var currentTaskID: UUID?
    private var generation: UInt64 = 0
    private var lastScheduledText: String?

    init(
        debounceDuration: Duration = .milliseconds(600),
        minimumCharacterDelta: Int = 3,
        sleep: @escaping SleepHandler = { duration in
            try? await Task.sleep(for: duration)
        },
        translate: @escaping TranslationHandler
    ) {
        self.debounceDuration = debounceDuration
        self.minimumCharacterDelta = minimumCharacterDelta
        self.sleep = sleep
        self.translate = translate
    }

    func unconfirmedSegmentDidChange(
        _ segment: TranscriptSegment,
        applyTranslation: @escaping ApplyTranslationHandler
    ) {
        generation += 1
        let currentGeneration = generation

        if let currentTaskID {
            translationTasks[currentTaskID]?.cancel()
            self.currentTaskID = nil
        }

        guard shouldScheduleTranslation(for: segment.text) else { return }

        lastScheduledText = segment.text
        let taskID = UUID.v7()
        currentTaskID = taskID
        translationTasks[taskID] = Task { [debounceDuration, sleep, translate] in
            await sleep(debounceDuration)
            if !Task.isCancelled {
                let translatedText = await translate(segment)
                if !Task.isCancelled, self.isCurrentGeneration(currentGeneration) {
                    await applyTranslation(segment.id, translatedText)
                }
            }
            self.translationTaskDidFinish(taskID)
        }
    }

    func cancelPending() {
        generation += 1
        translationTasks.values.forEach { $0.cancel() }
        currentTaskID = nil
        lastScheduledText = nil
    }

    func reset() async {
        cancelPending()

        while !translationTasks.isEmpty {
            let tasks = Array(translationTasks.values)
            translationTasks.removeAll()
            tasks.forEach { $0.cancel() }
            for task in tasks {
                await task.value
            }
        }
    }

    private func isCurrentGeneration(_ candidate: UInt64) -> Bool {
        generation == candidate
    }

    private func translationTaskDidFinish(_ taskID: UUID) {
        translationTasks[taskID] = nil
        if currentTaskID == taskID {
            currentTaskID = nil
        }
    }

    private func shouldScheduleTranslation(for newText: String) -> Bool {
        guard let previousText = lastScheduledText else { return true }

        if abs(newText.count - previousText.count) >= minimumCharacterDelta {
            return true
        }

        return Self.trailingBoundaryMarker(in: newText) != Self.trailingBoundaryMarker(in: previousText)
    }

    private static func trailingBoundaryMarker(in text: String) -> Character? {
        guard let last = text.last(where: { !$0.isWhitespace }) else { return nil }
        if last.isNewline || last.isPunctuation { return last }
        return nil
    }
}
