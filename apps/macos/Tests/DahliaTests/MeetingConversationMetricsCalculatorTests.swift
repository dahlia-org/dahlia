import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct MeetingConversationMetricsCalculatorTests {
        private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        @Test
        func removesWhitespaceAndMergesIntervalsBeforeCalculatingOverlap() {
            let session = makeSession(duration: 30)
            let input = makeInput(
                sessions: [session],
                segments: [
                    makeSegment(session: session, start: 0, end: 10, text: "あ い\nう", source: .microphone),
                    makeSegment(session: session, start: 5, end: 15, text: "えお", source: .microphone),
                    makeSegment(session: session, start: 8, end: 12, text: "peer", source: .system),
                ]
            )

            let metrics = MeetingConversationMetricsCalculator.calculate(input: input, fingerprint: "test")

            #expect(metrics.source(.microphone).speechDuration == 15)
            #expect(metrics.source(.microphone).normalizedCharacterCount == 5)
            #expect(metrics.source(.microphone).segmentCount == 2)
            #expect(metrics.source(.system).speechDuration == 4)
            #expect(metrics.unionSpeechDuration == 15)
            #expect(metrics.overlapDuration == 4)
            #expect(metrics.speechShare(for: .microphone) == 15.0 / 19.0)
            #expect(metrics.timelineIntervals == [
                .init(source: .microphone, start: 0, end: 15),
                .init(source: .system, start: 8, end: 12),
            ])
            #expect(metrics.overlapIntervals == [
                .init(start: 8, end: 12),
            ])
            #expect(metrics.overlapCount == 1)
            #expect(metrics.timelineDuration == 30)
        }

        @Test
        func shortGapsContributeToSpeechMetricsAndDerivedRatios() {
            let session = makeSession(duration: 10)
            let input = makeInput(
                sessions: [session],
                segments: [
                    makeSegment(session: session, start: 0, end: 1, source: .microphone),
                    makeSegment(session: session, start: 2.25, end: 3, source: .microphone),
                    makeSegment(session: session, start: 5, end: 6, source: .microphone),
                    makeSegment(session: session, start: 1.25, end: 2, source: .system),
                ]
            )

            let oneSecond = MeetingConversationMetricsCalculator.calculate(
                input: input,
                fingerprint: "one-second",
                speechMergeGap: 1
            )
            let oneAndAHalfSeconds = MeetingConversationMetricsCalculator.calculate(
                input: input,
                fingerprint: "one-and-a-half-seconds"
            )

            #expect(oneSecond.source(.microphone).speechDuration == 2.75)
            #expect(oneSecond.timelineIntervals == [
                .init(source: .microphone, start: 0, end: 1),
                .init(source: .microphone, start: 2.25, end: 3),
                .init(source: .microphone, start: 5, end: 6),
                .init(source: .system, start: 1.25, end: 2),
            ])
            #expect(oneSecond.unionSpeechDuration == 3.5)
            #expect(oneSecond.overlapDuration == 0)

            #expect(oneAndAHalfSeconds.source(.microphone).speechDuration == 4)
            #expect(oneAndAHalfSeconds.timelineIntervals == [
                .init(source: .microphone, start: 0, end: 3),
                .init(source: .microphone, start: 5, end: 6),
                .init(source: .system, start: 1.25, end: 2),
            ])
            #expect(oneAndAHalfSeconds.unionSpeechDuration == 4)
            #expect(oneAndAHalfSeconds.overlapDuration == 0.75)
            #expect(oneAndAHalfSeconds.speechShare(for: .microphone) == 4.0 / 4.75)
            #expect(oneAndAHalfSeconds.conversationOccupancyRatio == 0.4)
            #expect(oneAndAHalfSeconds.overlapRatio == 0.1875)
            #expect(oneAndAHalfSeconds.speechMergeGap == 1.5)
        }

        @Test
        func longestMonologueUsesIndependentThreeSecondGapAcrossOtherSourceSpeech() {
            let session = makeSession(duration: 20)
            let input = makeInput(
                sessions: [session],
                segments: [
                    makeSegment(session: session, start: 0, end: 2, source: .microphone),
                    makeSegment(session: session, start: 4, end: 6, source: .microphone),
                    makeSegment(session: session, start: 2.5, end: 3.5, source: .system),
                ]
            )

            let metrics = MeetingConversationMetricsCalculator.calculate(input: input, fingerprint: "monologue")

            #expect(metrics.source(.microphone).speechDuration == 4)
            #expect(metrics.timelineIntervals == [
                .init(source: .microphone, start: 0, end: 2),
                .init(source: .microphone, start: 4, end: 6),
                .init(source: .system, start: 2.5, end: 3.5),
            ])
            #expect(metrics.monologueMergeGap == 3)
            #expect(metrics.longestMonologue == .init(source: .microphone, start: 0, end: 6))
        }

        @Test
        func longestMonologueCanJoinAcrossRecordingSessionBoundaries() {
            let first = makeSession(duration: 5)
            let second = makeSession(start: 120, duration: 5, offset: 7)
            let input = makeInput(
                sessions: [first, second],
                segments: [
                    makeSegment(session: first, start: 4, end: 5, source: .microphone),
                    makeSegment(session: second, start: 0, end: 2, source: .microphone),
                ]
            )

            let metrics = MeetingConversationMetricsCalculator.calculate(input: input, fingerprint: "sessions")

            #expect(metrics.longestMonologue == .init(source: .microphone, start: 4, end: 9))
        }

        @Test
        func longestMonologueIncludesExactBoundaryAndUsesDeterministicTieBreaks() {
            let session = makeSession(duration: 40)
            let input = makeInput(
                sessions: [session],
                segments: [
                    makeSegment(session: session, start: 0, end: 1, source: .system),
                    makeSegment(session: session, start: 4, end: 7, source: .system),
                    makeSegment(session: session, start: 10.1, end: 14.1, source: .system),
                    makeSegment(session: session, start: 20, end: 24, source: .system),
                    makeSegment(session: session, start: 20, end: 24, source: .microphone),
                    makeSegment(session: session, start: 30, end: 37, source: .microphone),
                ]
            )

            let metrics = MeetingConversationMetricsCalculator.calculate(input: input, fingerprint: "boundaries")

            #expect(metrics.longestMonologue == .init(source: .system, start: 0, end: 7))

            let tied = MeetingConversationMetricsCalculator.calculate(
                input: makeInput(
                    sessions: [session],
                    segments: [
                        makeSegment(session: session, start: 20, end: 24, source: .system),
                        makeSegment(session: session, start: 20, end: 24, source: .microphone),
                    ]
                ),
                fingerprint: "tie"
            )

            #expect(tied.longestMonologue == .init(source: .microphone, start: 20, end: 24))
        }

        @Test
        func clampsSessionIntervalsAndSumsRecordingSessions() {
            let first = makeSession(duration: 10)
            let second = makeSession(start: 20, duration: 5, offset: 10)
            let input = makeInput(
                sessions: [first, second],
                segments: [
                    makeSegment(session: first, start: -5, end: 15, source: .microphone),
                    makeSegment(session: second, start: 2, end: 9, source: .system),
                ]
            )

            let metrics = MeetingConversationMetricsCalculator.calculate(input: input, fingerprint: "test")

            #expect(metrics.recordingDuration == 15)
            #expect(metrics.source(.microphone).speechDuration == 10)
            #expect(metrics.source(.system).speechDuration == 3)
            #expect(metrics.unionSpeechDuration == 13)
            #expect(metrics.overlapDuration == 0)
        }

        @Test
        func allLegacySegmentsPreserveTheirInternalOverlap() {
            let input = makeInput(
                meetingDuration: 20,
                segments: [
                    makeLegacySegment(start: 10, end: 16, source: .microphone),
                    makeLegacySegment(start: 13, end: 18, source: .system),
                ]
            )

            let metrics = MeetingConversationMetricsCalculator.calculate(input: input, fingerprint: "test")

            #expect(metrics.recordingDuration == 20)
            #expect(metrics.unionSpeechDuration == 8)
            #expect(metrics.overlapDuration == 3)
            #expect(metrics.conversationOccupancyRatio == 0.4)
            #expect(metrics.usesLegacyTimelineFallback)
        }

        @Test
        func legacySegmentsFollowKnownSessionsWithoutCreatingFalseOverlap() {
            let session = makeSession(duration: 10)
            let missingSessionId = UUID()
            let input = makeInput(
                sessions: [session],
                segments: [
                    makeSegment(session: session, start: 0, end: 10, source: .microphone),
                    makeLegacySegment(start: 0, end: 5, sessionId: nil, source: .system),
                    makeLegacySegment(start: 2, end: 6, sessionId: missingSessionId, source: .microphone),
                ]
            )

            let metrics = MeetingConversationMetricsCalculator.calculate(input: input, fingerprint: "test")

            #expect(metrics.source(.microphone).speechDuration == 14)
            #expect(metrics.source(.system).speechDuration == 5)
            #expect(metrics.unionSpeechDuration == 16)
            #expect(metrics.overlapDuration == 3)
            #expect(metrics.recordingDuration == 16)
            #expect(metrics.conversationOccupancyRatio == 1)
            #expect(metrics.usesLegacyTimelineFallback)
            #expect(metrics.timelineIntervals == [
                .init(source: .microphone, start: 0, end: 10),
                .init(source: .microphone, start: 12, end: 16),
                .init(source: .system, start: 10, end: 15),
            ])
            #expect(metrics.overlapIntervals == [
                .init(start: 12, end: 15),
            ])
            #expect(metrics.timelineDuration == 16)
        }

        @Test
        func timelineProjectionIsBoundedWithoutChangingExactOverlapCount() {
            let intervalCount = MeetingConversationMetricsCalculator.maximumTimelineIntervalsPerLane + 100
            let session = makeSession(duration: TimeInterval(intervalCount * 4))
            let segments = (0 ..< intervalCount).flatMap { index in
                let start = TimeInterval(index * 4)
                return [
                    makeSegment(session: session, start: start, end: start + 1, source: .microphone),
                    makeSegment(session: session, start: start, end: start + 1, source: .system),
                ]
            }
            let metrics = MeetingConversationMetricsCalculator.calculate(
                input: makeInput(sessions: [session], segments: segments),
                fingerprint: "bounded"
            )

            #expect(metrics.isTimelineCondensed)
            #expect(metrics.timelineIntervals.count <= MeetingConversationMetricsCalculator.maximumTimelineIntervalsPerLane * 2)
            #expect(metrics.overlapIntervals.count <= MeetingConversationMetricsCalculator.maximumTimelineIntervalsPerLane)
            #expect(metrics.paceSamples.count <= MeetingConversationMetricsCalculator.maximumPaceSamplesPerSource * 2)
            #expect(metrics.overlapCount == intervalCount)
            #expect(metrics.overlapDuration == TimeInterval(intervalCount))
        }

        @Test
        func speakingPaceSamplesUseMergedSpeechTimeAndBreakAcrossSilence() {
            let session = makeSession(duration: 180)
            let input = makeInput(
                sessions: [session],
                segments: [
                    makeSegment(
                        session: session,
                        start: 0,
                        end: 30,
                        text: String(repeating: "あ", count: 60),
                        source: .microphone
                    ),
                    makeSegment(
                        session: session,
                        start: 31,
                        end: 60,
                        text: String(repeating: "い", count: 60),
                        source: .microphone
                    ),
                    makeSegment(
                        session: session,
                        start: 120,
                        end: 150,
                        text: String(repeating: "う", count: 30),
                        source: .microphone
                    ),
                    makeSegment(
                        session: session,
                        start: 0,
                        end: 60,
                        text: String(repeating: "a", count: 60),
                        source: .system
                    ),
                ]
            )

            let metrics = MeetingConversationMetricsCalculator.calculate(input: input, fingerprint: "pace")

            #expect(metrics.paceBucketDuration == 60)
            #expect(metrics.paceSamples == [
                .init(source: .microphone, start: 0, end: 60, charactersPerMinute: 120, seriesIndex: 0),
                .init(source: .microphone, start: 120, end: 180, charactersPerMinute: 60, seriesIndex: 1),
                .init(source: .system, start: 0, end: 60, charactersPerMinute: 60, seriesIndex: 0),
            ])
        }

        @Test
        func wiresStoredAudioFeaturesIntoVoiceAnalytics() {
            let session = makeSession(duration: 20)
            let features = TranscriptAudioFeatures(
                activeRmsDecibels: -18,
                medianPitchHertz: 220,
                voicedFrameRatio: 0.8,
                pitchSpreadHertz: 20
            )
            let segments = (0 ..< 10).map { index in
                makeSegment(
                    session: session,
                    start: Double(index),
                    end: Double(index + 1),
                    source: .microphone,
                    audioFeatures: features
                )
            }

            let metrics = MeetingConversationMetricsCalculator.calculate(
                input: makeInput(sessions: [session], segments: segments),
                fingerprint: "features"
            )

            #expect(metrics.voiceAnalytics.status(for: .microphone) == .available)
            #expect(metrics.voiceAnalytics.expressions.first?.loudnessVariationDecibels == 0)
        }

        @Test
        func invalidTimesStillContributeTextAndSegmentCounts() {
            let session = makeSession(duration: 10)
            let input = makeInput(
                sessions: [session],
                segments: [
                    makeSegment(session: session, start: 1, end: nil, text: "a b", source: .microphone),
                    makeSegment(session: session, start: 5, end: 3, text: "cd", source: .microphone),
                    makeSegment(session: session, start: 10, end: 12, text: "ef", source: .microphone),
                ]
            )

            let metrics = MeetingConversationMetricsCalculator.calculate(input: input, fingerprint: "test")
            let microphone = metrics.source(.microphone)

            #expect(microphone.normalizedCharacterCount == 6)
            #expect(microphone.segmentCount == 3)
            #expect(microphone.unmeasurableSegmentCount == 3)
            #expect(microphone.speechDuration == 0)
            #expect(microphone.charactersPerMinute == nil)
            #expect(metrics.conversationOccupancyRatio == 0)
            #expect(metrics.overlapRatio == nil)
            #expect(metrics.longestMonologue == nil)
        }

        @Test
        func unknownSourcesAreExcludedAndBothKnownSourcesRemainAvailable() {
            let session = makeSession(duration: 10)
            let input = MeetingConversationMetricsInput(
                meetingDuration: nil,
                sessions: [session],
                segments: [
                    .init(
                        id: UUID(),
                        sessionId: session.id,
                        startTime: session.startedAt,
                        endTime: session.startedAt.addingTimeInterval(5),
                        text: "ignored",
                        speakerLabel: "speaker-1"
                    ),
                ]
            )

            let metrics = MeetingConversationMetricsCalculator.calculate(input: input, fingerprint: "test")

            #expect(!metrics.hasSegments)
            #expect(metrics.sources.count == 2)
            #expect(metrics.source(.microphone).segmentCount == 0)
            #expect(metrics.source(.system).segmentCount == 0)
        }

        @Test
        func fingerprintIsStableAndOnlyIncludesMetricInputs() throws {
            let session = makeSession(duration: 10)
            let segment = makeSegment(session: session, start: 1, end: 2, text: "hello", source: .microphone)
            let input = makeInput(meetingDuration: 12, sessions: [session], segments: [segment])
            let reordered = MeetingConversationMetricsInput(
                meetingDuration: 12,
                sessions: [session],
                segments: [segment]
            )

            #expect(try input.fingerprint() == reordered.fingerprint())

            let changedText = makeInput(meetingDuration: 12, sessions: [session], segments: [
                .init(
                    id: segment.id,
                    sessionId: segment.sessionId,
                    startTime: segment.startTime,
                    endTime: segment.endTime,
                    text: "world",
                    speakerLabel: segment.speakerLabel
                ),
            ])
            let changedTiming = makeInput(
                meetingDuration: 12,
                sessions: [makeSession(id: session.id, duration: 11)],
                segments: [segment]
            )
            let removedByConfirmation = makeInput(meetingDuration: 12, sessions: [session], segments: [])
            var segmentWithFeatures = segment
            segmentWithFeatures.audioFeatures = TranscriptAudioFeatures(
                activeRmsDecibels: -18,
                medianPitchHertz: 220,
                voicedFrameRatio: 0.8,
                pitchSpreadHertz: 20
            )
            let withFeatures = makeInput(meetingDuration: 12, sessions: [session], segments: [segmentWithFeatures])

            #expect(try input.fingerprint() != changedText.fingerprint())
            #expect(try input.fingerprint() != changedTiming.fingerprint())
            #expect(try input.fingerprint() != removedByConfirmation.fingerprint())
            #expect(try input.fingerprint() == withFeatures.fingerprint())
        }

        private func makeInput(
            meetingDuration: TimeInterval? = nil,
            sessions: [MeetingConversationMetricsInput.Session] = [],
            segments: [MeetingConversationMetricsInput.Segment]
        ) -> MeetingConversationMetricsInput {
            MeetingConversationMetricsInput(
                meetingDuration: meetingDuration,
                sessions: sessions,
                segments: segments
            )
        }

        private func makeSession(
            id: UUID = UUID(),
            start: TimeInterval = 0,
            duration: TimeInterval,
            offset: TimeInterval = 0
        ) -> MeetingConversationMetricsInput.Session {
            .init(
                id: id,
                startedAt: baseDate.addingTimeInterval(start),
                duration: duration,
                offsetSeconds: offset
            )
        }

        private func makeSegment(
            session: MeetingConversationMetricsInput.Session,
            start: TimeInterval,
            end: TimeInterval?,
            text: String = "text",
            source: RecordingAudioSource,
            audioFeatures: TranscriptAudioFeatures? = nil
        ) -> MeetingConversationMetricsInput.Segment {
            .init(
                id: UUID(),
                sessionId: session.id,
                startTime: session.startedAt.addingTimeInterval(start),
                endTime: end.map(session.startedAt.addingTimeInterval),
                text: text,
                speakerLabel: source.speakerLabel,
                audioFeatures: audioFeatures
            )
        }

        private func makeLegacySegment(
            start: TimeInterval,
            end: TimeInterval,
            sessionId: UUID? = nil,
            source: RecordingAudioSource
        ) -> MeetingConversationMetricsInput.Segment {
            .init(
                id: UUID(),
                sessionId: sessionId,
                startTime: baseDate.addingTimeInterval(start),
                endTime: baseDate.addingTimeInterval(end),
                text: "text",
                speakerLabel: source.speakerLabel
            )
        }
    }
#endif
