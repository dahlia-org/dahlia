@preconcurrency import AVFoundation
import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct BatchManualTranscriptionRunPlannerTests {
        @Test
        func joinsContiguousPhysicalSegmentsWithMatchingSourceFormatAndLocale() throws {
            let sessionID = UUID.v7()
            let recordingStart = Date(timeIntervalSince1970: 1_776_384_000)
            let verified = [
                makeVerified(
                    sessionID: sessionID,
                    segmentIndex: 0,
                    source: .microphone,
                    startOffset: 0,
                    frameCount: 160,
                    locale: "ja_JP"
                ),
                makeVerified(
                    sessionID: sessionID,
                    segmentIndex: 1,
                    source: .microphone,
                    startOffset: 0.01,
                    frameCount: 320,
                    locale: "ja_JP"
                ),
            ]

            let runs = try BatchManualTranscriptionRunPlanner.runs(
                verifiedSegments: verified,
                recordingStartTime: recordingStart,
                audioFormatProvider: { try audioFormat(for: $0) }
            )

            #expect(runs.count == 1)
            #expect(runs[0].slices.count == 2)
            #expect(runs[0].fileIndices == [0, 1])
            #expect(runs[0].localeIdentifier == "ja_JP")
            #expect(runs[0].sessionOffsetSeconds == 0)
        }

        @Test
        func splitsRunsAtLocaleSourceGapAndFormatBoundaries() throws {
            let sessionID = UUID.v7()
            let recordingStart = Date(timeIntervalSince1970: 1_776_384_000)
            let verified = [
                makeVerified(
                    sessionID: sessionID,
                    segmentIndex: 0,
                    source: .microphone,
                    startOffset: 0,
                    frameCount: 160,
                    locale: "ja_JP"
                ),
                makeVerified(
                    sessionID: sessionID,
                    segmentIndex: 1,
                    source: .microphone,
                    startOffset: 0.01,
                    frameCount: 160,
                    locale: "en_US"
                ),
                makeVerified(
                    sessionID: sessionID,
                    segmentIndex: 2,
                    source: .microphone,
                    startOffset: 0.03,
                    frameCount: 160,
                    locale: "en_US"
                ),
                makeVerified(
                    sessionID: sessionID,
                    segmentIndex: 3,
                    source: .microphone,
                    startOffset: 0.04,
                    frameCount: 320,
                    sampleRate: 32000,
                    locale: "en_US"
                ),
                makeVerified(
                    sessionID: sessionID,
                    segmentIndex: 0,
                    source: .system,
                    startOffset: 0,
                    frameCount: 160,
                    locale: "ja_JP"
                ),
            ]

            let runs = try BatchManualTranscriptionRunPlanner.runs(
                verifiedSegments: verified,
                recordingStartTime: recordingStart,
                audioFormatProvider: { try audioFormat(for: $0) }
            )

            #expect(runs.count == 5)
            #expect(runs.map(\.localeIdentifier) == ["ja_JP", "en_US", "en_US", "en_US", "ja_JP"])
            #expect(runs.map(\.source) == [.microphone, .microphone, .microphone, .microphone, .system])
        }

        @Test
        func splitsRunsWhenCAFProcessingFormatsDiffer() throws {
            let sessionID = UUID.v7()
            let recordingStart = Date(timeIntervalSince1970: 1_776_384_000)
            let verified = [
                makeVerified(
                    sessionID: sessionID,
                    segmentIndex: 0,
                    source: .microphone,
                    startOffset: 0,
                    frameCount: 160,
                    locale: "ja_JP"
                ),
                makeVerified(
                    sessionID: sessionID,
                    segmentIndex: 1,
                    source: .microphone,
                    startOffset: 0.01,
                    frameCount: 160,
                    locale: "ja_JP"
                ),
            ]

            let runs = try BatchManualTranscriptionRunPlanner.runs(
                verifiedSegments: verified,
                recordingStartTime: recordingStart,
                audioFormatProvider: { segment in
                    try audioFormat(
                        for: segment,
                        commonFormat: segment.segment.segmentIndex == 0 ? .pcmFormatInt16 : .pcmFormatFloat32
                    )
                }
            )

            #expect(runs.count == 2)
            #expect(runs.map(\.slices.count) == [1, 1])
        }

        private func audioFormat(
            for verified: RecordingAudioStore.VerifiedSegment,
            commonFormat: AVAudioCommonFormat = .pcmFormatInt16
        ) throws -> AVAudioFormat {
            try #require(AVAudioFormat(
                commonFormat: commonFormat,
                sampleRate: verified.segment.sampleRate,
                channels: AVAudioChannelCount(verified.segment.channelCount),
                interleaved: false
            ))
        }

        private func makeVerified(
            sessionID: UUID,
            segmentIndex: Int,
            source: RecordingAudioSource,
            startOffset: TimeInterval,
            frameCount: Int64,
            sampleRate: Double = 16000,
            channelCount: Int = 1,
            locale: String
        ) -> RecordingAudioStore.VerifiedSegment {
            let now = Date(timeIntervalSince1970: 1_776_384_000)
            let segmentID = UUID.v7()
            let segment = RecordingAudioSegmentRecord(
                id: segmentID,
                recordingSessionId: sessionID,
                source: source,
                segmentIndex: segmentIndex,
                generationId: .v7(),
                state: .ready,
                partialRelativePath: "\(source.rawValue)-\(segmentIndex).partial.caf",
                finalRelativePath: "\(source.rawValue)-\(segmentIndex).caf",
                sampleRate: sampleRate,
                channelCount: channelCount,
                sealedFrameCount: frameCount,
                sessionStartOffsetSeconds: startOffset,
                sessionEndOffsetSeconds: startOffset + Double(frameCount) / sampleRate,
                byteCount: frameCount * Int64(channelCount) * 2,
                sha256: Data(),
                finalizationStartedAt: now,
                integrityVerifiedAt: now,
                finalizedAt: now,
                purgeRequestedAt: nil,
                purgedAt: nil,
                failureStage: nil,
                failureCode: nil,
                createdAt: now,
                updatedAt: now
            )
            let range = RecordingAudioSegmentRangeRecord(
                id: .v7(),
                audioSegmentId: segmentID,
                startFrame: 0,
                frameCount: frameCount,
                sessionOffsetSeconds: startOffset,
                localeIdentifier: locale,
                createdAt: now,
                updatedAt: now
            )
            return RecordingAudioStore.VerifiedSegment(
                segment: segment,
                url: URL(fileURLWithPath: "/tmp/\(segment.finalRelativePath)"),
                ranges: [range]
            )
        }
    }
#endif
