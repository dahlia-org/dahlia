import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct BatchTranscriptionAudioRangePlannerTests {
        @Test
        func automaticModeCoalescesContiguousLocaleRangesForOnePhysicalSegment() throws {
            let now = Date(timeIntervalSince1970: 1_776_384_000)
            let segmentID = UUID.v7()
            let verified = RecordingAudioStore.VerifiedSegment(
                segment: makeSegment(id: segmentID, now: now),
                url: URL(fileURLWithPath: "/tmp/audio.caf"),
                ranges: [
                    makeRange(segmentID: segmentID, startFrame: 0, frameCount: 160, offset: 4, locale: "ja_JP"),
                    makeRange(segmentID: segmentID, startFrame: 160, frameCount: 320, offset: 4.01, locale: "en_US"),
                ]
            )

            let ranges = try BatchTranscriptionAudioRangePlanner.ranges(for: verified, mode: .automatic)

            #expect(ranges.count == 1)
            #expect(ranges[0].startFrame == 0)
            #expect(ranges[0].frameCount == 480)
            #expect(ranges[0].sessionOffsetSeconds == 4)
            #expect(ranges[0].recordedLocaleIdentifiers == ["ja_JP", "en_US"])
        }

        @Test
        func manualModePreservesLocaleRanges() throws {
            let now = Date(timeIntervalSince1970: 1_776_384_000)
            let segmentID = UUID.v7()
            let verified = RecordingAudioStore.VerifiedSegment(
                segment: makeSegment(id: segmentID, now: now),
                url: URL(fileURLWithPath: "/tmp/audio.caf"),
                ranges: [
                    makeRange(segmentID: segmentID, startFrame: 0, frameCount: 160, offset: 0, locale: "ja_JP"),
                    makeRange(segmentID: segmentID, startFrame: 160, frameCount: 160, offset: 0.01, locale: "en_US"),
                ]
            )

            let ranges = try BatchTranscriptionAudioRangePlanner.ranges(for: verified, mode: .manual)

            #expect(ranges.map(\.recordedLocaleIdentifiers) == [["ja_JP"], ["en_US"]])
            #expect(ranges.map(\.frameCount) == [160, 160])
        }

        private func makeSegment(id: UUID, now: Date) -> RecordingAudioSegmentRecord {
            RecordingAudioSegmentRecord(
                id: id,
                recordingSessionId: .v7(),
                source: .microphone,
                segmentIndex: 0,
                generationId: .v7(),
                state: .ready,
                partialRelativePath: "audio.partial.caf",
                finalRelativePath: "audio.caf",
                sampleRate: 16000,
                channelCount: 1,
                sealedFrameCount: 480,
                sessionStartOffsetSeconds: 4,
                sessionEndOffsetSeconds: 4.03,
                byteCount: 960,
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
        }

        private func makeRange(
            segmentID: UUID,
            startFrame: Int64,
            frameCount: Int64,
            offset: TimeInterval,
            locale: String
        ) -> RecordingAudioSegmentRangeRecord {
            let now = Date(timeIntervalSince1970: 1_776_384_000)
            return RecordingAudioSegmentRangeRecord(
                id: .v7(),
                audioSegmentId: segmentID,
                startFrame: startFrame,
                frameCount: frameCount,
                sessionOffsetSeconds: offset,
                localeIdentifier: locale,
                createdAt: now,
                updatedAt: now
            )
        }
    }
#endif
