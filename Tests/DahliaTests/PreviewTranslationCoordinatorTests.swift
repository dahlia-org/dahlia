import Foundation
@testable import Dahlia

#if canImport(Testing)
import Testing

struct PreviewTranslationCoordinatorTests {
    @Test
    func waitsForDebounceBeforeTranslating() async {
        let sleepGate = SleepGate()
        let recorder = PreviewTranslationRecorder()
        let coordinator = PreviewTranslationCoordinator(
            sleep: { duration in
                await sleepGate.wait(duration: duration)
            },
            translate: { segment in
                await recorder.recordTranslate(text: segment.text)
                return "訳: \(segment.text)"
            }
        )

        await coordinator.unconfirmedSegmentDidChange(
            TranscriptSegment(startTime: .now, text: "Hello", isConfirmed: false)
        ) { segmentID, translatedText in
            await recorder.recordApply(segmentID: segmentID, translatedText: translatedText)
        }

        await sleepGate.waitUntilWaiting()
        #expect(await recorder.translateCallCount() == 0)

        await sleepGate.release()

        #expect(await waitUntil { await recorder.translateCallCount() == 1 })
        #expect(await recorder.appliedTexts() == ["訳: Hello"])
    }

    @Test
    func ignoresSmallChangesUntilThresholdIsReached() async {
        let recorder = PreviewTranslationRecorder()
        let coordinator = PreviewTranslationCoordinator(
            sleep: { _ in },
            translate: { segment in
                await recorder.recordTranslate(text: segment.text)
                return "訳: \(segment.text)"
            }
        )

        await coordinator.unconfirmedSegmentDidChange(
            TranscriptSegment(startTime: .now, text: "Hello", isConfirmed: false)
        ) { _, _ in }
        await coordinator.unconfirmedSegmentDidChange(
            TranscriptSegment(startTime: .now, text: "Helloa", isConfirmed: false)
        ) { _, _ in }
        await coordinator.unconfirmedSegmentDidChange(
            TranscriptSegment(startTime: .now, text: "Helloabc", isConfirmed: false)
        ) { _, _ in }

        #expect(await waitUntil { await recorder.translateCallCount() == 2 })
        #expect(await recorder.translatedTexts() == ["Hello", "Helloabc"])
    }

    @Test
    func reTranslatesWhenTrailingBoundaryChanges() async {
        let recorder = PreviewTranslationRecorder()
        let coordinator = PreviewTranslationCoordinator(
            sleep: { _ in },
            translate: { segment in
                await recorder.recordTranslate(text: segment.text)
                return "訳: \(segment.text)"
            }
        )

        await coordinator.unconfirmedSegmentDidChange(
            TranscriptSegment(startTime: .now, text: "Hello", isConfirmed: false)
        ) { _, _ in }
        await coordinator.unconfirmedSegmentDidChange(
            TranscriptSegment(startTime: .now, text: "Hello.", isConfirmed: false)
        ) { _, _ in }

        #expect(await waitUntil { await recorder.translateCallCount() == 2 })
        #expect(await recorder.translatedTexts() == ["Hello", "Hello."])
    }

    @Test
    func dropsStaleResultWhenTextChangesDuringTranslation() async {
        let translator = BlockingTranslator()
        let recorder = PreviewTranslationRecorder()
        let firstSegmentID = UUID.v7()
        let secondSegmentID = UUID.v7()
        let thirdSegmentID = UUID.v7()
        let coordinator = PreviewTranslationCoordinator(
            sleep: { _ in },
            translate: { segment in
                await recorder.recordTranslate(text: segment.text)
                return await translator.translate(text: segment.text)
            }
        )

        await coordinator.unconfirmedSegmentDidChange(
            TranscriptSegment(id: firstSegmentID, startTime: .now, text: "Hello", isConfirmed: false)
        ) { segmentID, translatedText in
            await recorder.recordApply(segmentID: segmentID, translatedText: translatedText)
        }

        await translator.waitUntilStarted()

        await coordinator.unconfirmedSegmentDidChange(
            TranscriptSegment(id: secondSegmentID, startTime: .now, text: "Helloa", isConfirmed: false)
        ) { segmentID, translatedText in
            await recorder.recordApply(segmentID: segmentID, translatedText: translatedText)
        }

        await translator.resume(with: "古い訳")

        #expect(await waitUntil { await recorder.appliedTexts().isEmpty })
        #expect(await recorder.appliedTexts().isEmpty)

        await coordinator.unconfirmedSegmentDidChange(
            TranscriptSegment(id: thirdSegmentID, startTime: .now, text: "Helloabc", isConfirmed: false)
        ) { segmentID, translatedText in
            await recorder.recordApply(segmentID: segmentID, translatedText: translatedText)
        }

        await translator.waitUntilStarted(count: 2)
        await translator.resume(with: "新しい訳")

        #expect(await waitUntil { await recorder.appliedTexts() == ["新しい訳"] })
        #expect(await recorder.appliedTexts() == ["新しい訳"])
        #expect(await recorder.appliedSegmentIDs() == [thirdSegmentID])
    }
}

#elseif canImport(XCTest)
import XCTest

final class PreviewTranslationCoordinatorTests: XCTestCase {
    func testWaitsForDebounceBeforeTranslating() async {
        let sleepGate = SleepGate()
        let recorder = PreviewTranslationRecorder()
        let coordinator = PreviewTranslationCoordinator(
            sleep: { duration in
                await sleepGate.wait(duration: duration)
            },
            translate: { segment in
                await recorder.recordTranslate(text: segment.text)
                return "訳: \(segment.text)"
            }
        )

        await coordinator.unconfirmedSegmentDidChange(
            TranscriptSegment(startTime: .now, text: "Hello", isConfirmed: false)
        ) { segmentID, translatedText in
            await recorder.recordApply(segmentID: segmentID, translatedText: translatedText)
        }

        await sleepGate.waitUntilWaiting()
        let countBeforeRelease = await recorder.translateCallCount()
        XCTAssertEqual(countBeforeRelease, 0)

        await sleepGate.release()

        let didTranslate = await waitUntil { await recorder.translateCallCount() == 1 }
        let appliedTexts = await recorder.appliedTexts()
        XCTAssertTrue(didTranslate)
        XCTAssertEqual(appliedTexts, ["訳: Hello"])
    }

    func testIgnoresSmallChangesUntilThresholdIsReached() async {
        let recorder = PreviewTranslationRecorder()
        let coordinator = PreviewTranslationCoordinator(
            sleep: { _ in },
            translate: { segment in
                await recorder.recordTranslate(text: segment.text)
                return "訳: \(segment.text)"
            }
        )

        await coordinator.unconfirmedSegmentDidChange(
            TranscriptSegment(startTime: .now, text: "Hello", isConfirmed: false)
        ) { _, _ in }
        await coordinator.unconfirmedSegmentDidChange(
            TranscriptSegment(startTime: .now, text: "Helloa", isConfirmed: false)
        ) { _, _ in }
        await coordinator.unconfirmedSegmentDidChange(
            TranscriptSegment(startTime: .now, text: "Helloabc", isConfirmed: false)
        ) { _, _ in }

        let didTranslate = await waitUntil { await recorder.translateCallCount() == 2 }
        let translatedTexts = await recorder.translatedTexts()
        XCTAssertTrue(didTranslate)
        XCTAssertEqual(translatedTexts, ["Hello", "Helloabc"])
    }

    func testReTranslatesWhenTrailingBoundaryChanges() async {
        let recorder = PreviewTranslationRecorder()
        let coordinator = PreviewTranslationCoordinator(
            sleep: { _ in },
            translate: { segment in
                await recorder.recordTranslate(text: segment.text)
                return "訳: \(segment.text)"
            }
        )

        await coordinator.unconfirmedSegmentDidChange(
            TranscriptSegment(startTime: .now, text: "Hello", isConfirmed: false)
        ) { _, _ in }
        await coordinator.unconfirmedSegmentDidChange(
            TranscriptSegment(startTime: .now, text: "Hello.", isConfirmed: false)
        ) { _, _ in }

        let didTranslate = await waitUntil { await recorder.translateCallCount() == 2 }
        let translatedTexts = await recorder.translatedTexts()
        XCTAssertTrue(didTranslate)
        XCTAssertEqual(translatedTexts, ["Hello", "Hello."])
    }

    func testDropsStaleResultWhenTextChangesDuringTranslation() async {
        let translator = BlockingTranslator()
        let recorder = PreviewTranslationRecorder()
        let firstSegmentID = UUID.v7()
        let secondSegmentID = UUID.v7()
        let thirdSegmentID = UUID.v7()
        let coordinator = PreviewTranslationCoordinator(
            sleep: { _ in },
            translate: { segment in
                await recorder.recordTranslate(text: segment.text)
                return await translator.translate(text: segment.text)
            }
        )

        await coordinator.unconfirmedSegmentDidChange(
            TranscriptSegment(id: firstSegmentID, startTime: .now, text: "Hello", isConfirmed: false)
        ) { segmentID, translatedText in
            await recorder.recordApply(segmentID: segmentID, translatedText: translatedText)
        }

        await translator.waitUntilStarted()

        await coordinator.unconfirmedSegmentDidChange(
            TranscriptSegment(id: secondSegmentID, startTime: .now, text: "Helloa", isConfirmed: false)
        ) { segmentID, translatedText in
            await recorder.recordApply(segmentID: segmentID, translatedText: translatedText)
        }

        await translator.resume(with: "古い訳")

        let didDropStaleText = await waitUntil { await recorder.appliedTexts().isEmpty }
        let staleAppliedTexts = await recorder.appliedTexts()
        XCTAssertTrue(didDropStaleText)
        XCTAssertTrue(staleAppliedTexts.isEmpty)

        await coordinator.unconfirmedSegmentDidChange(
            TranscriptSegment(id: thirdSegmentID, startTime: .now, text: "Helloabc", isConfirmed: false)
        ) { segmentID, translatedText in
            await recorder.recordApply(segmentID: segmentID, translatedText: translatedText)
        }

        await translator.waitUntilStarted(count: 2)
        await translator.resume(with: "新しい訳")

        let didApplyLatestText = await waitUntil { await recorder.appliedTexts() == ["新しい訳"] }
        let latestAppliedTexts = await recorder.appliedTexts()
        let appliedSegmentIDs = await recorder.appliedSegmentIDs()
        XCTAssertTrue(didApplyLatestText)
        XCTAssertEqual(latestAppliedTexts, ["新しい訳"])
        XCTAssertEqual(appliedSegmentIDs, [thirdSegmentID])
    }
}
#endif

private actor PreviewTranslationRecorder {
    private var translated: [String] = []
    private var applied: [(UUID, String?)] = []

    func recordTranslate(text: String) {
        translated.append(text)
    }

    func recordApply(segmentID: UUID, translatedText: String?) {
        applied.append((segmentID, translatedText))
    }

    func translateCallCount() -> Int {
        translated.count
    }

    func translatedTexts() -> [String] {
        translated
    }

    func appliedTexts() -> [String] {
        applied.compactMap(\.1)
    }

    func appliedSegmentIDs() -> [UUID] {
        applied.map(\.0)
    }
}

private actor SleepGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait(duration _: Duration) async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }

    func waitUntilWaiting() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor BlockingTranslator {
    private var continuations: [CheckedContinuation<String?, Never>] = []
    private var startedCount = 0
    private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func translate(text _: String) async -> String? {
        startedCount += 1
        let readyWaiters = startWaiters.filter { startedCount >= $0.count }
        startWaiters.removeAll { startedCount >= $0.count }
        readyWaiters.forEach { $0.continuation.resume() }

        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitUntilStarted(count: Int = 1) async {
        guard startedCount < count else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append((count, continuation))
        }
    }

    func resume(with text: String?) {
        guard !continuations.isEmpty else { return }
        let continuation = continuations.removeFirst()
        continuation.resume(returning: text)
    }
}

private func waitUntil(
    timeout: Duration = .seconds(1),
    condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout

    while clock.now < deadline {
        if await condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(10))
    }

    return await condition()
}
