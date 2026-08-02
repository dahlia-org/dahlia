import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct MeetingVoiceAnalyticsCalculatorTests {
        @Test
        func distinguishesUnavailableInsufficientAndAvailableSources() {
            let sessionId = UUID()
            let insufficient = (0 ..< 9).map {
                segment(index: $0, source: .microphone, sessionId: sessionId)
            }
            let available = (0 ..< 10).map {
                segment(index: $0, source: .system, sessionId: sessionId)
            }

            let analytics = calculate(insufficient + available)

            #expect(analytics.status(for: .microphone) == .insufficientSamples)
            #expect(analytics.status(for: .system) == .available)
            #expect(analytics.hasAvailableSource)
            #expect(calculate([]).status(for: .microphone) == .unavailable)
        }

        @Test
        func excludesMismatchedFeatureVersions() {
            let sessionId = UUID()
            let segments = (0 ..< 10).map {
                segment(index: $0, source: .microphone, sessionId: sessionId, version: 99)
            }

            #expect(calculate(segments).status(for: .microphone) == .unavailable)
        }

        @Test
        func sessionGainChangesDoNotCreateEnergyTrend() throws {
            let firstSession = UUID()
            let secondSession = UUID()
            let first = (0 ..< 5).map {
                segment(index: $0, source: .microphone, sessionId: firstSession, loudness: -30)
            }
            let second = (0 ..< 5).map {
                segment(
                    index: $0 + 5,
                    source: .microphone,
                    sessionId: secondSession,
                    loudness: -10
                )
            }

            let analytics = calculate(first + second, timelineDuration: 10, bucketDuration: 1)
            let samples = analytics.energyTrend.samples.filter { $0.source == .microphone }

            #expect(samples.count == 10)
            #expect(try abs(#require(analytics.energyTrend.slopePerMinute[.microphone])) < 0.001)
            #expect(!analytics.energyTrend.decliningSources.contains(.microphone))
        }

        @Test
        func smoothingResetsAtSessionBoundaries() throws {
            var configuration = MeetingVoiceAnalyticsCalculator.Configuration.default
            configuration.minimumPitchSampleCount = 100
            let firstSession = UUID()
            let secondSession = UUID()
            let first = (0 ..< 5).map {
                segment(index: $0, source: .microphone, sessionId: firstSession, loudness: -20)
            }
            let second = (0 ..< 5).map {
                segment(
                    index: $0 + 5,
                    source: .microphone,
                    sessionId: secondSession,
                    loudness: $0 == 0 ? -10 : -20
                )
            }

            let analytics = calculate(
                first + second,
                timelineDuration: 10,
                bucketDuration: 1,
                configuration: configuration
            )
            let score = try #require(analytics.excitement.samples.first { $0.start == 5 })

            #expect(score.value == 3)
        }

        @Test
        func hotspotMinimumUsesCoveredDurationInsteadOfSpan() {
            var configuration = MeetingVoiceAnalyticsCalculator.Configuration.default
            configuration.smoothingWindowSize = 1
            configuration.minimumPitchSampleCount = 100
            configuration.hotspotThreshold = 1
            let sessionId = UUID()
            let baseline = (0 ..< 10).map {
                segment(index: $0, source: .microphone, sessionId: sessionId, loudness: -30)
            }
            let spikes = [
                segment(start: 20, end: 21, source: .microphone, sessionId: sessionId, loudness: -10),
                segment(start: 30, end: 31, source: .microphone, sessionId: sessionId, loudness: -10),
            ]

            let analytics = calculate(
                baseline + spikes,
                timelineDuration: 40,
                bucketDuration: 1,
                configuration: configuration
            )

            #expect(analytics.excitement.hotspots.isEmpty)
        }

        @Test
        func chartSamplesAreBoundedWithoutTruncatingTimeline() throws {
            let sessionId = UUID()
            let segments = (0 ..< 120).map {
                segment(index: $0, source: .microphone, sessionId: sessionId, loudness: -30 + Double($0 % 5))
            }

            let analytics = calculate(segments, timelineDuration: 120, bucketDuration: 1)
            let samples = analytics.excitement.samples.filter { $0.source == .microphone }

            #expect(samples.count <= 60)
            #expect(try #require(samples.last).end == 120)
        }

        @Test
        func pitchSpreadIsRequiredForPitchAnalysis() {
            let sessionId = UUID()
            let segments = (0 ..< 10).map {
                segment(
                    index: $0,
                    source: .microphone,
                    sessionId: sessionId,
                    pitch: 200 + Double($0),
                    pitchSpread: nil
                )
            }

            let analytics = calculate(segments)

            #expect(analytics.expressions.first { $0.source == .microphone }?.pitchVariationSemitones == nil)
            #expect(!analytics.excitement.sourcesUsingPitch.contains(.microphone))
        }

        @Test
        func expressionAxesAreClassifiedIndependently() throws {
            let sessionId = UUID()
            let segments = (0 ..< 10).map {
                segment(
                    index: $0,
                    source: .microphone,
                    sessionId: sessionId,
                    loudness: $0.isMultiple(of: 2) ? -30 : -20,
                    pitch: 200,
                    pitchSpread: 1
                )
            }

            let expression = try #require(calculate(segments).expressions.first { $0.source == .microphone })

            #expect(expression.pitchLevel == .low)
            #expect(expression.loudnessLevel == .high)
        }

        @Test
        func pitchExcitementIsIndependentOfAbsoluteRegister() throws {
            var configuration = MeetingVoiceAnalyticsCalculator.Configuration.default
            configuration.smoothingWindowSize = 1
            let microphoneSession = UUID()
            let systemSession = UUID()
            let oneSemitone = pow(2.0, 1.0 / 12.0)
            let microphone = (0 ..< 10).map {
                segment(
                    index: $0,
                    source: .microphone,
                    sessionId: microphoneSession,
                    pitch: $0 == 9 ? 100 * oneSemitone : 100
                )
            }
            let system = (0 ..< 10).map {
                segment(
                    index: $0,
                    source: .system,
                    sessionId: systemSession,
                    pitch: $0 == 9 ? 300 * oneSemitone : 300
                )
            }

            let samples = calculate(
                microphone + system,
                timelineDuration: 10,
                configuration: configuration
            ).excitement.samples
            let microphoneScore = try #require(samples.first { $0.source == .microphone && $0.start == 9 })
            let systemScore = try #require(samples.first { $0.source == .system && $0.start == 9 })

            #expect(abs(microphoneScore.value - systemScore.value) < 0.000_001)
        }

        @Test
        func detectsPitchConvergenceAcrossBuckets() throws {
            let microphoneSession = UUID()
            let systemSession = UUID()
            let microphone = (0 ..< 12).map {
                segment(
                    index: $0,
                    source: .microphone,
                    sessionId: microphoneSession,
                    pitch: 200,
                    pitchSpread: 10
                )
            }
            let system = (0 ..< 12).map {
                segment(
                    index: $0,
                    source: .system,
                    sessionId: systemSession,
                    pitch: 300 - Double($0 * 8),
                    pitchSpread: 10
                )
            }

            let entrainment = try #require(
                calculate(microphone + system, timelineDuration: 12, bucketDuration: 2).pitchEntrainment
            )

            #expect(entrainment.distanceSamples.count == 6)
            #expect(entrainment.isConverging)
            #expect(entrainment.lastThirdMeanDistance < entrainment.firstThirdMeanDistance)
        }
    }

    extension MeetingVoiceAnalyticsCalculatorTests {
        @Test
        func excludesInsufficientSourceFromAnalytics() throws {
            let microphoneSession = UUID()
            let systemSession = UUID()
            let microphone = (0 ..< 10).map {
                segment(index: $0, source: .microphone, sessionId: microphoneSession)
            }
            let system = (0 ..< 5).map {
                segment(index: $0, source: .system, sessionId: systemSession)
            }

            let analytics = calculate(microphone + system, timelineDuration: 10)
            let systemExpression = try #require(analytics.expressions.first { $0.source == .system })

            #expect(analytics.status(for: .microphone) == .available)
            #expect(analytics.status(for: .system) == .insufficientSamples)
            #expect(!analytics.excitement.samples.contains { $0.source == .system })
            #expect(!analytics.energyTrend.samples.contains { $0.source == .system })
            #expect(systemExpression.pitchVariationSemitones == nil)
            #expect(systemExpression.loudnessVariationDecibels == nil)
            #expect(analytics.pitchEntrainment == nil)
        }

        @Test
        func requiresEnoughSamplesWithinEligibleSessions() {
            let segments = (0 ..< 5).flatMap { sessionIndex in
                let sessionId = UUID()
                return (0 ..< 2).map { index in
                    segment(
                        index: sessionIndex * 2 + index,
                        source: .microphone,
                        sessionId: sessionId
                    )
                }
            }

            let analytics = calculate(segments, timelineDuration: 10)

            #expect(analytics.status(for: .microphone) == .insufficientSamples)
            #expect(!analytics.hasAvailableSource)
            #expect(analytics.excitement.samples.isEmpty)
            #expect(analytics.energyTrend.samples.isEmpty)
        }

        @Test
        func pitchDistanceSeriesBreaksAcrossMissingBuckets() throws {
            let microphoneSession = UUID()
            let systemSession = UUID()
            let buckets = [0, 0, 0, 1, 1, 10, 10, 10, 11, 11]
            let microphone = buckets.enumerated().map { index, bucket in
                segment(
                    start: Double(bucket) + Double(index % 3) * 0.1,
                    end: Double(bucket) + Double(index % 3) * 0.1 + 0.05,
                    source: .microphone,
                    sessionId: microphoneSession,
                    pitch: 200
                )
            }
            let system = buckets.enumerated().map { index, bucket in
                segment(
                    start: Double(bucket) + Double(index % 3) * 0.1,
                    end: Double(bucket) + Double(index % 3) * 0.1 + 0.05,
                    source: .system,
                    sessionId: systemSession,
                    pitch: 250
                )
            }

            let entrainment = try #require(
                calculate(microphone + system, timelineDuration: 12).pitchEntrainment
            )

            #expect(entrainment.distanceSamples.map(\.seriesIndex) == [0, 0, 1, 1])
        }

        @Test
        func hotspotMergingTracksTheFurthestCoveredEnd() throws {
            var configuration = MeetingVoiceAnalyticsCalculator.Configuration.default
            configuration.minimumSourceSampleCount = 3
            configuration.minimumSessionSampleCount = 3
            configuration.minimumPitchSampleCount = 100
            configuration.smoothingWindowSize = 1
            configuration.hotspotThreshold = -1
            configuration.minimumHotspotCoveredDuration = 0
            let sessionId = UUID()
            let segments = [
                segment(start: 0, end: 100, source: .microphone, sessionId: sessionId),
                segment(start: 1, end: 2, source: .microphone, sessionId: sessionId),
                segment(start: 90, end: 91, source: .microphone, sessionId: sessionId),
            ]

            let hotspots = calculate(
                segments,
                timelineDuration: 100,
                configuration: configuration
            ).excitement.hotspots

            #expect(hotspots.count == 1)
            let hotspot = try #require(hotspots.first)
            #expect(hotspot.start == 0)
            #expect(hotspot.end == 100)
        }

        private func calculate(
            _ segments: [MeetingVoiceAnalyticsCalculator.MeasuredSegment],
            timelineDuration: TimeInterval = 60,
            bucketDuration: TimeInterval = 1,
            configuration: MeetingVoiceAnalyticsCalculator.Configuration = .default
        ) -> MeetingVoiceAnalytics {
            MeetingVoiceAnalyticsCalculator.calculate(
                segments: segments,
                timelineDuration: timelineDuration,
                bucketDuration: bucketDuration,
                configuration: configuration
            )
        }

        private func segment(
            index: Int,
            source: RecordingAudioSource,
            sessionId: UUID,
            version: Int = TranscriptAudioFeatures.currentVersion,
            loudness: Double = -20,
            pitch: Double? = 200,
            pitchSpread: Double? = 10
        ) -> MeetingVoiceAnalyticsCalculator.MeasuredSegment {
            segment(
                start: Double(index),
                end: Double(index + 1),
                source: source,
                sessionId: sessionId,
                version: version,
                loudness: loudness,
                pitch: pitch,
                pitchSpread: pitchSpread
            )
        }

        private func segment(
            start: TimeInterval,
            end: TimeInterval,
            source: RecordingAudioSource,
            sessionId: UUID,
            version: Int = TranscriptAudioFeatures.currentVersion,
            loudness: Double = -20,
            pitch: Double? = 200,
            pitchSpread: Double? = 10
        ) -> MeetingVoiceAnalyticsCalculator.MeasuredSegment {
            .init(
                source: source,
                sessionId: sessionId,
                start: start,
                end: end,
                audioFeatures: TranscriptAudioFeatures(
                    version: version,
                    activeRmsDecibels: loudness,
                    medianPitchHertz: pitch,
                    voicedFrameRatio: 1,
                    pitchSpreadHertz: pitchSpread
                )
            )
        }
    }
#endif
