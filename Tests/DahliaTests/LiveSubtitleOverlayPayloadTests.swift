import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct LiveSubtitleOverlayPayloadTests {
        @Test
        func latestDefaultsToSystemAudioOnly() {
            let payload = LiveSubtitleOverlayPayload.latest(
                from: [
                    TranscriptSegment(
                        startTime: Date(timeIntervalSince1970: 1_776_384_000),
                        text: "Microphone",
                        isConfirmed: true,
                        speakerLabel: "mic"
                    ),
                    TranscriptSegment(
                        startTime: Date(timeIntervalSince1970: 1_776_384_001),
                        text: "System",
                        isConfirmed: true,
                        speakerLabel: "system"
                    ),
                ],
                transcriptionLocaleIdentifier: "en_US",
                translationEnabled: false,
                targetLanguageIdentifier: "ja",
                maxEntries: 2
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
                maxEntries: 2
            )

            #expect(payload == nil)
        }

        @Test
        func latestUsesOriginalTextForUnconfirmedSegment() {
            let payload = LiveSubtitleOverlayPayload.latest(
                from: [
                    TranscriptSegment(
                        startTime: Date(timeIntervalSince1970: 1_776_384_000),
                        text: "  Hello world  ",
                        isConfirmed: false,
                        speakerLabel: "mic"
                    ),
                ],
                sourceMode: .includeMicrophone,
                transcriptionLocaleIdentifier: "en_US",
                translationEnabled: true,
                targetLanguageIdentifier: "ja",
                maxEntries: 2
            )

            #expect(payload?.entries == [
                LiveSubtitleOverlayPayload.Entry(primaryText: "Hello world", secondaryText: nil),
            ])
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
                        speakerLabel: "mic"
                    ),
                ],
                sourceMode: .includeMicrophone,
                transcriptionLocaleIdentifier: "en_US",
                translationEnabled: true,
                targetLanguageIdentifier: "ja",
                maxEntries: 2
            )

            #expect(payload?.entries == [
                LiveSubtitleOverlayPayload.Entry(primaryText: "Hello world", secondaryText: "こんにちは、世界"),
            ])
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
                        speakerLabel: "mic"
                    ),
                ],
                sourceMode: .includeMicrophone,
                transcriptionLocaleIdentifier: "en_US",
                translationEnabled: true,
                targetLanguageIdentifier: "en",
                maxEntries: 2
            )

            #expect(payload?.entries == [
                LiveSubtitleOverlayPayload.Entry(primaryText: "Hello world", secondaryText: nil),
            ])
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
                maxEntries: 2
            )

            #expect(payload?.entries == [
                LiveSubtitleOverlayPayload.Entry(primaryText: "Current line", secondaryText: nil),
            ])
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
                        speakerLabel: "mic"
                    ),
                    TranscriptSegment(
                        startTime: Date(timeIntervalSince1970: 1_776_384_000),
                        text: "Mic first",
                        translatedText: "マイク最初",
                        isConfirmed: true,
                        speakerLabel: "mic"
                    ),
                    TranscriptSegment(
                        startTime: Date(timeIntervalSince1970: 1_776_384_001),
                        text: "System latest",
                        translatedText: "システム最新",
                        isConfirmed: true,
                        speakerLabel: "system"
                    ),
                ],
                sourceMode: .includeMicrophone,
                transcriptionLocaleIdentifier: "en_US",
                translationEnabled: true,
                targetLanguageIdentifier: "ja",
                maxEntries: 2
            )

            #expect(payload?.entries == [
                LiveSubtitleOverlayPayload.Entry(primaryText: "Mic first", secondaryText: "マイク最初"),
                LiveSubtitleOverlayPayload.Entry(primaryText: "System latest", secondaryText: "システム最新"),
            ])
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
                        speakerLabel: "mic"
                    ),
                    TranscriptSegment(
                        startTime: Date(timeIntervalSince1970: 1_776_384_001),
                        text: "Unconfirmed current",
                        isConfirmed: false,
                        speakerLabel: "system"
                    ),
                ],
                sourceMode: .includeMicrophone,
                transcriptionLocaleIdentifier: "en_US",
                translationEnabled: true,
                targetLanguageIdentifier: "ja",
                maxEntries: 2
            )

            #expect(payload?.entries == [
                LiveSubtitleOverlayPayload.Entry(primaryText: "Confirmed line", secondaryText: "確定済み"),
                LiveSubtitleOverlayPayload.Entry(primaryText: "Unconfirmed current", secondaryText: nil),
            ])
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
                        speakerLabel: "system"
                    ),
                ],
                sourceMode: .includeMicrophone,
                transcriptionLocaleIdentifier: "en_US",
                translationEnabled: true,
                targetLanguageIdentifier: "ja",
                maxEntries: 2
            )

            #expect(payload?.entries == [
                LiveSubtitleOverlayPayload.Entry(primaryText: "Unconfirmed current", secondaryText: "未確定の現在行"),
            ])
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
                maxEntries: 1
            )

            #expect(payload?.entries == [
                LiveSubtitleOverlayPayload.Entry(primaryText: "Three", secondaryText: nil),
            ])
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
                        speakerLabel: "mic"
                    ),
                    TranscriptSegment(
                        startTime: Date(timeIntervalSince1970: 1_776_384_001),
                        text: "System line",
                        translatedText: "システム",
                        isConfirmed: true,
                        speakerLabel: "system"
                    ),
                ],
                sourceMode: .systemAudioOnly,
                transcriptionLocaleIdentifier: "en_US",
                translationEnabled: true,
                targetLanguageIdentifier: "ja",
                maxEntries: 2
            )

            #expect(payload?.entries == [
                LiveSubtitleOverlayPayload.Entry(primaryText: "System line", secondaryText: "システム"),
            ])
        }

        @Test
        func latestReturnsNilWhenNoSystemAudioExistsInSystemOnlyMode() {
            let payload = LiveSubtitleOverlayPayload.latest(
                from: [
                    TranscriptSegment(
                        startTime: Date(timeIntervalSince1970: 1_776_384_000),
                        text: "Mic only",
                        isConfirmed: true,
                        speakerLabel: "mic"
                    ),
                ],
                sourceMode: .systemAudioOnly,
                transcriptionLocaleIdentifier: "en_US",
                translationEnabled: false,
                targetLanguageIdentifier: "ja",
                maxEntries: 2
            )

            #expect(payload == nil)
        }
    }
#endif
