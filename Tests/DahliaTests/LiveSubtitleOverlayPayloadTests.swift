import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct LiveSubtitleOverlayPayloadTests {
        @Test
        func latestDefaultsToSystemAudioOnly() {
            let payload = LiveSubtitleOverlayPayload.history(
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
                visibleEntryCount: 2
            )

            #expect(payload?.entries.map(\.primaryText) == ["System"])
        }

        @Test
        func latestReturnsNilForEmptySegments() {
            let payload = LiveSubtitleOverlayPayload.history(
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
        func historyPreservesSegmentIdentityAndLimitsOnlyTheVisibleWindow() throws {
            let firstID = UUID.v7()
            let secondID = UUID.v7()
            let payload = LiveSubtitleOverlayPayload.history(
                from: [
                    TranscriptSegment(
                        id: firstID,
                        startTime: Date(timeIntervalSince1970: 1_776_384_000),
                        text: "First",
                        isConfirmed: true,
                        speakerLabel: "system"
                    ),
                    TranscriptSegment(
                        id: secondID, startTime: Date(timeIntervalSince1970: 1_776_384_001), text: "Second", isConfirmed: true, speakerLabel: "system"
                    ),
                ],
                transcriptionLocaleIdentifier: "en_US",
                translationEnabled: false,
                targetLanguageIdentifier: "ja",
                visibleEntryCount: 1
            )

            let requiredPayload = try #require(payload)
            #expect(requiredPayload.entries.map(\.id) == [firstID, secondID])
            #expect(requiredPayload.visibleEntries.map(\.id) == [secondID])
        }

        @Test
        func latestUsesOriginalTextForUnconfirmedSegment() {
            let payload = LiveSubtitleOverlayPayload.history(
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
                visibleEntryCount: 2
            )

            #expect(payload?.entries.map(\.primaryText) == ["Hello world"])
            #expect(payload?.entries.map(\.secondaryText) == [nil])
        }

        @Test
        func latestIncludesTranslatedTextWhenTranslationIsEffective() {
            let payload = LiveSubtitleOverlayPayload.history(
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
                visibleEntryCount: 2
            )

            #expect(payload?.entries.map(\.primaryText) == ["Hello world"])
            #expect(payload?.entries.map(\.secondaryText) == ["こんにちは、世界"])
        }

        @Test
        func latestSkipsTranslatedTextWhenTargetMatchesSourceLanguage() {
            let payload = LiveSubtitleOverlayPayload.history(
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
                visibleEntryCount: 2
            )

            #expect(payload?.entries.map(\.primaryText) == ["Hello world"])
            #expect(payload?.entries.map(\.secondaryText) == [nil])
        }

        @Test
        func latestIgnoresWhitespaceOnlyTextAndTranslation() {
            let payload = LiveSubtitleOverlayPayload.history(
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
            let payload = LiveSubtitleOverlayPayload.history(
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
                visibleEntryCount: 2
            )

            #expect(payload?.entries.map(\.primaryText) == ["Earlier line", "Mic first", "System latest"])
            #expect(payload?.visibleEntries.map(\.primaryText) == ["Mic first", "System latest"])
        }

        @Test
        func latestIncludesUnconfirmedMessagesInRecentTwoSegments() {
            let payload = LiveSubtitleOverlayPayload.history(
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
                visibleEntryCount: 2
            )

            #expect(payload?.entries.map(\.primaryText) == ["Confirmed line", "Unconfirmed current"])
            #expect(payload?.entries.map(\.secondaryText) == ["確定済み", nil])
        }

        @Test
        func latestIncludesTranslatedTextForUnconfirmedSegmentWhenAvailable() {
            let payload = LiveSubtitleOverlayPayload.history(
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
                visibleEntryCount: 2
            )

            #expect(payload?.entries.map(\.primaryText) == ["Unconfirmed current"])
            #expect(payload?.entries.map(\.secondaryText) == ["未確定の現在行"])
        }

        @Test
        func latestRespectsConfiguredSegmentCount() {
            let payload = LiveSubtitleOverlayPayload.history(
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

            #expect(payload?.entries.map(\.primaryText) == ["One", "Two", "Three"])
            #expect(payload?.visibleEntries.map(\.primaryText) == ["Three"])
        }

        @Test
        func latestCanRestrictSubtitlesToSystemAudioOnly() {
            let payload = LiveSubtitleOverlayPayload.history(
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
                visibleEntryCount: 2
            )

            #expect(payload?.entries.map(\.primaryText) == ["System line"])
            #expect(payload?.entries.map(\.secondaryText) == ["システム"])
        }

        @Test
        func latestReturnsNilWhenNoSystemAudioExistsInSystemOnlyMode() {
            let payload = LiveSubtitleOverlayPayload.history(
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
                visibleEntryCount: 2
            )

            #expect(payload == nil)
        }
    }

    extension LiveSubtitleOverlayPayloadTests {
        @Test
        func projectorAppliesIncrementalCaptionChangesWithoutDroppingHistory() throws {
            let configuration = LiveSubtitleOverlayPayload.Configuration(
                sourceMode: .includeMicrophone,
                transcriptionLocaleIdentifier: "en_US",
                translationEnabled: true,
                targetLanguageIdentifier: "ja"
            )
            let history = (0 ..< 25).map {
                TranscriptSegment(
                    startTime: Date(timeIntervalSince1970: 1_776_384_000 + Double($0)),
                    text: "Segment \($0)",
                    isConfirmed: true,
                    speakerLabel: "system"
                )
            }
            let preview = TranscriptSegment(startTime: .now, text: "Preview", speakerLabel: "system")
            let finalized = TranscriptSegment(id: preview.id, startTime: .now, text: "Final", isConfirmed: true, speakerLabel: "system")
            var translated = finalized
            translated.translatedText = "確定"
            let projector = LiveSubtitleOverlayPayloadProjector()

            projector.apply(.reload)
            let initialPayload = try #require(projector.payload(
                from: history,
                configuration: configuration,
                visibleEntryCount: 5
            ))
            projector.apply(.preview(preview))
            projector.apply(.finalized(finalized))
            projector.apply(.update(translated))

            let payload = try #require(projector.payload(
                from: [],
                configuration: configuration,
                visibleEntryCount: 5
            ))
            #expect(initialPayload.entries === payload.entries)
            #expect(payload.entries.count == 26)
            #expect(payload.entries.first?.primaryText == "Segment 0")
            #expect(payload.entries.last?.id == finalized.id)
            #expect(payload.entries.last?.primaryText == "Final")
            #expect(payload.entries.last?.secondaryText == "確定")
        }
    }
#endif
