import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct LiveSubtitleOverlayPayloadTests {
        @Test
        func latestDefaultsToSystemAudioOnly() {
            let payload = LiveSubtitleOverlayPayload.latest(
                from: [
                    TranscriptSegment(
                        startTime: Date(timeIntervalSince1970: 1_776_384_000),
                        text: "Microphone",
                        isConfirmed: true,
                        audioSource: "mic"
                    ),
                    TranscriptSegment(
                        startTime: Date(timeIntervalSince1970: 1_776_384_001),
                        text: "System",
                        isConfirmed: true,
                        audioSource: "system"
                    ),
                ],
                transcriptionLocaleIdentifier: "en_US",
                translationEnabled: false,
                targetLanguageIdentifier: "ja",
                visibleEntryCount: 2
            )

            #expect(payload?.entries.map(\.primaryText) == ["System"])
        }

        @Test
        func latestReturnsNilForEmptySegments() {
            let payload = LiveSubtitleOverlayPayload.latest(
                from: [],
                sourceMode: .includeMicrophone,
                transcriptionLocaleIdentifier: "en_US",
                translationEnabled: true,
                targetLanguageIdentifier: "ja",
                visibleEntryCount: 2
            )

            #expect(payload == nil)
        }

        @Test
        func latestKeepsSegmentIdentityAndOnlyTheVisibleWindow() throws {
            let firstID = UUID.v7()
            let secondID = UUID.v7()
            let payload = LiveSubtitleOverlayPayload.latest(
                from: [
                    TranscriptSegment(
                        id: firstID,
                        startTime: Date(timeIntervalSince1970: 1_776_384_000),
                        text: "First",
                        isConfirmed: true,
                        audioSource: "system"
                    ),
                    TranscriptSegment(
                        id: secondID, startTime: Date(timeIntervalSince1970: 1_776_384_001), text: "Second", isConfirmed: true, audioSource: "system"
                    ),
                ],
                transcriptionLocaleIdentifier: "en_US",
                translationEnabled: false,
                targetLanguageIdentifier: "ja",
                visibleEntryCount: 1
            )

            let requiredPayload = try #require(payload)
            #expect(requiredPayload.entries.map(\.id) == [secondID])
        }

        @Test
        func latestUsesOriginalTextForUnconfirmedSegment() {
            let payload = LiveSubtitleOverlayPayload.latest(
                from: [
                    TranscriptSegment(
                        startTime: Date(timeIntervalSince1970: 1_776_384_000),
                        text: "  Hello world  ",
                        isConfirmed: false,
                        audioSource: "mic"
                    ),
                ],
                sourceMode: .includeMicrophone,
                transcriptionLocaleIdentifier: "en_US",
                translationEnabled: true,
                targetLanguageIdentifier: "ja",
                visibleEntryCount: 2
            )

            #expect(payload?.entries.map(\.primaryText) == ["Hello world"])
            #expect(payload?.entries.map(\.secondaryText) == [nil])
        }

        @Test
        func latestIncludesTranslatedTextWhenTranslationIsEffective() {
            let payload = LiveSubtitleOverlayPayload.latest(
                from: [
                    TranscriptSegment(
                        startTime: Date(timeIntervalSince1970: 1_776_384_000),
                        text: "Hello world",
                        translatedText: "こんにちは、世界",
                        isConfirmed: true,
                        audioSource: "mic"
                    ),
                ],
                sourceMode: .includeMicrophone,
                transcriptionLocaleIdentifier: "en_US",
                translationEnabled: true,
                targetLanguageIdentifier: "ja",
                visibleEntryCount: 2
            )

            #expect(payload?.entries.map(\.primaryText) == ["Hello world"])
            #expect(payload?.entries.map(\.secondaryText) == ["こんにちは、世界"])
        }

        @Test
        func latestSkipsTranslatedTextWhenTargetMatchesSourceLanguage() {
            let payload = LiveSubtitleOverlayPayload.latest(
                from: [
                    TranscriptSegment(
                        startTime: Date(timeIntervalSince1970: 1_776_384_000),
                        text: "Hello world",
                        translatedText: "Hello world",
                        isConfirmed: true,
                        audioSource: "mic"
                    ),
                ],
                sourceMode: .includeMicrophone,
                transcriptionLocaleIdentifier: "en_US",
                translationEnabled: true,
                targetLanguageIdentifier: "en",
                visibleEntryCount: 2
            )

            #expect(payload?.entries.map(\.primaryText) == ["Hello world"])
            #expect(payload?.entries.map(\.secondaryText) == [nil])
        }

        @Test
        func latestIgnoresWhitespaceOnlyTextAndTranslation() {
            let payload = LiveSubtitleOverlayPayload.latest(
                from: [
                    TranscriptSegment(
                        startTime: Date(timeIntervalSince1970: 1_776_384_000),
                        text: "   ",
                        translatedText: "   ",
                        isConfirmed: true
                    ),
                    TranscriptSegment(
                        startTime: Date(timeIntervalSince1970: 1_776_384_100),
                        text: "Current line",
                        translatedText: "   ",
                        isConfirmed: true
                    ),
                ],
                sourceMode: .includeMicrophone,
                transcriptionLocaleIdentifier: "en_US",
                translationEnabled: true,
                targetLanguageIdentifier: "ja",
                visibleEntryCount: 2
            )

            #expect(payload?.entries.map(\.primaryText) == ["Current line"])
            #expect(payload?.entries.map(\.secondaryText) == [nil])
        }

        @Test
        func latestUsesTwoMostRecentlyUpdatedSegmentsAcrossSources() {
            let payload = LiveSubtitleOverlayPayload.latest(
                from: [
                    TranscriptSegment(
                        startTime: Date(timeIntervalSince1970: 1_776_384_000),
                        text: "Earlier line",
                        translatedText: "ひとつ前",
                        isConfirmed: true,
                        audioSource: "mic"
                    ),
                    TranscriptSegment(
                        startTime: Date(timeIntervalSince1970: 1_776_384_000),
                        text: "Mic first",
                        translatedText: "マイク最初",
                        isConfirmed: true,
                        audioSource: "mic"
                    ),
                    TranscriptSegment(
                        startTime: Date(timeIntervalSince1970: 1_776_384_001),
                        text: "System latest",
                        translatedText: "システム最新",
                        isConfirmed: true,
                        audioSource: "system"
                    ),
                ],
                sourceMode: .includeMicrophone,
                transcriptionLocaleIdentifier: "en_US",
                translationEnabled: true,
                targetLanguageIdentifier: "ja",
                visibleEntryCount: 2
            )

            #expect(payload?.entries.map(\.primaryText) == ["Mic first", "System latest"])
        }

        @Test
        func latestIncludesUnconfirmedMessagesInRecentTwoSegments() {
            let payload = LiveSubtitleOverlayPayload.latest(
                from: [
                    TranscriptSegment(
                        startTime: Date(timeIntervalSince1970: 1_776_384_000),
                        text: "Confirmed line",
                        translatedText: "確定済み",
                        isConfirmed: true,
                        audioSource: "mic"
                    ),
                    TranscriptSegment(
                        startTime: Date(timeIntervalSince1970: 1_776_384_001),
                        text: "Unconfirmed current",
                        isConfirmed: false,
                        audioSource: "system"
                    ),
                ],
                sourceMode: .includeMicrophone,
                transcriptionLocaleIdentifier: "en_US",
                translationEnabled: true,
                targetLanguageIdentifier: "ja",
                visibleEntryCount: 2
            )

            #expect(payload?.entries.map(\.primaryText) == ["Confirmed line", "Unconfirmed current"])
            #expect(payload?.entries.map(\.secondaryText) == ["確定済み", nil])
            #expect(payload?.entries.map(\.isConfirmed) == [true, false])
        }

        @Test
        func latestIncludesTranslatedTextForUnconfirmedSegmentWhenAvailable() {
            let payload = LiveSubtitleOverlayPayload.latest(
                from: [
                    TranscriptSegment(
                        startTime: Date(timeIntervalSince1970: 1_776_384_001),
                        text: "Unconfirmed current",
                        translatedText: "未確定の現在行",
                        isConfirmed: false,
                        audioSource: "system"
                    ),
                ],
                sourceMode: .includeMicrophone,
                transcriptionLocaleIdentifier: "en_US",
                translationEnabled: true,
                targetLanguageIdentifier: "ja",
                visibleEntryCount: 2
            )

            #expect(payload?.entries.map(\.primaryText) == ["Unconfirmed current"])
            #expect(payload?.entries.map(\.secondaryText) == ["未確定の現在行"])
        }

        @Test
        func latestRespectsConfiguredSegmentCount() {
            let payload = LiveSubtitleOverlayPayload.latest(
                from: [
                    TranscriptSegment(startTime: Date(timeIntervalSince1970: 1_776_384_000), text: "One", isConfirmed: true),
                    TranscriptSegment(startTime: Date(timeIntervalSince1970: 1_776_384_001), text: "Two", isConfirmed: true),
                    TranscriptSegment(startTime: Date(timeIntervalSince1970: 1_776_384_002), text: "Three", isConfirmed: true),
                ],
                sourceMode: .includeMicrophone,
                transcriptionLocaleIdentifier: "en_US",
                translationEnabled: false,
                targetLanguageIdentifier: "ja",
                visibleEntryCount: 1
            )

            #expect(payload?.entries.map(\.primaryText) == ["Three"])
        }

        @Test
        func latestCanRestrictSubtitlesToSystemAudioOnly() {
            let payload = LiveSubtitleOverlayPayload.latest(
                from: [
                    TranscriptSegment(
                        startTime: Date(timeIntervalSince1970: 1_776_384_000),
                        text: "Mic line",
                        translatedText: "マイク",
                        isConfirmed: true,
                        audioSource: "mic"
                    ),
                    TranscriptSegment(
                        startTime: Date(timeIntervalSince1970: 1_776_384_001),
                        text: "System line",
                        translatedText: "システム",
                        isConfirmed: true,
                        audioSource: "system"
                    ),
                ],
                sourceMode: .systemAudioOnly,
                transcriptionLocaleIdentifier: "en_US",
                translationEnabled: true,
                targetLanguageIdentifier: "ja",
                visibleEntryCount: 2
            )

            #expect(payload?.entries.map(\.primaryText) == ["System line"])
            #expect(payload?.entries.map(\.secondaryText) == ["システム"])
        }

        @Test
        func latestReturnsNilWhenNoSystemAudioExistsInSystemOnlyMode() {
            let payload = LiveSubtitleOverlayPayload.latest(
                from: [
                    TranscriptSegment(
                        startTime: Date(timeIntervalSince1970: 1_776_384_000),
                        text: "Mic only",
                        isConfirmed: true,
                        audioSource: "mic"
                    ),
                ],
                sourceMode: .systemAudioOnly,
                transcriptionLocaleIdentifier: "en_US",
                translationEnabled: false,
                targetLanguageIdentifier: "ja",
                visibleEntryCount: 2
            )

            #expect(payload == nil)
        }
    }

#endif
