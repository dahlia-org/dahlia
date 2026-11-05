import Foundation

extension SyncWorker {
    static let transcriptChunkSize = 500
    private static let transcriptChunkMaximumBytes = 6 * 1024 * 1024

    static func transcriptChunks(
        _ snapshot: SyncTranscriptPatchSnapshot
    ) throws -> [(body: TranscriptChunkBody, data: Data)] {
        let segments = snapshot.segments.map {
            TranscriptChunkBody.Segment(
                segmentId: $0.segmentId,
                startedAt: $0.startTime,
                endedAt: $0.endTime,
                text: $0.text,
                createdAt: $0.createdAt,
                audioSource: $0.audioSource,
                speakerLabel: $0.speakerLabel
            )
        }
        var segmentOffset = 0
        var deletionOffset = 0
        var chunks: [(body: TranscriptChunkBody, data: Data)] = []
        repeat {
            let segmentEnd = min(segmentOffset + transcriptChunkSize, segments.count)
            let deletionEnd = min(deletionOffset + transcriptChunkSize, snapshot.deletions.count)
            let combined = TranscriptChunkBody(
                segments: Array(segments[segmentOffset ..< segmentEnd]),
                deletions: Array(snapshot.deletions[deletionOffset ..< deletionEnd])
            )
            let combinedData = try SyncJSON.encoder.encode(combined)
            if combinedData.count <= transcriptChunkMaximumBytes {
                chunks.append((combined, combinedData))
                segmentOffset = segmentEnd
                deletionOffset = deletionEnd
                continue
            }

            if segmentOffset < segmentEnd {
                let chunk = try largestTranscriptChunk(maximumCount: segmentEnd - segmentOffset) { count in
                    TranscriptChunkBody(
                        segments: Array(segments[segmentOffset ..< segmentOffset + count]),
                        deletions: []
                    )
                }
                chunks.append(chunk)
                segmentOffset += chunk.body.segments.count
            } else {
                let chunk = try largestTranscriptChunk(maximumCount: deletionEnd - deletionOffset) { count in
                    TranscriptChunkBody(
                        segments: [],
                        deletions: Array(snapshot.deletions[deletionOffset ..< deletionOffset + count])
                    )
                }
                chunks.append(chunk)
                deletionOffset += chunk.body.deletions.count
            }
        } while segmentOffset < segments.count || deletionOffset < snapshot.deletions.count || chunks.isEmpty
        return chunks
    }

    private static func largestTranscriptChunk(
        maximumCount: Int,
        body: (Int) -> TranscriptChunkBody
    ) throws -> (body: TranscriptChunkBody, data: Data) {
        var lower = 1
        var upper = maximumCount
        var result: (body: TranscriptChunkBody, data: Data)?
        while lower <= upper {
            let count = (lower + upper) / 2
            let candidate = body(count)
            let data = try SyncJSON.encoder.encode(candidate)
            if data.count <= transcriptChunkMaximumBytes {
                result = (candidate, data)
                lower = count + 1
            } else {
                upper = count - 1
            }
        }
        guard let result else { throw SyncTransactionQueueError.invalidReceipt }
        return result
    }
}
