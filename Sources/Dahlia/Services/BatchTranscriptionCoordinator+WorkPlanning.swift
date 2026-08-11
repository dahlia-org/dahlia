@preconcurrency import AVFoundation
import Foundation

extension BatchTranscriptionCoordinator {
    struct AutomaticTranscriptionConfiguration: Sendable {
        let supportedLocales: [Locale]
        let candidateLocales: [Locale]?
        let allowedLanguageIdentifiers: Set<String>?
        let languageDetector: any BatchLanguageDetecting
        let onLanguageFallback: @Sendable (BatchLanguageFallback) async -> Void
    }

    enum TranscriptionRequest: Sendable {
        case run(BatchTranscriptionRun)
        case noAudio(localeIdentifier: String)
    }

    struct TranscriptionWorkItem: Sendable {
        let index: Int
        let fileIndices: [Int]
        let request: TranscriptionRequest
    }

    struct TranscriptionWorkResult: Sendable {
        let index: Int
        var segments: [TranscriptSegment]
        let localeIdentifier: String
    }

    func transcriptionWorkItems(
        verifiedSegments: [RecordingAudioStore.VerifiedSegment],
        job: Job,
        automaticConfiguration: AutomaticTranscriptionConfiguration
    ) async throws -> [TranscriptionWorkItem] {
        switch job.session.batchLanguageDetectionMode {
        case .manual:
            let runs = try BatchTranscriptionRunPlanner.manualRuns(
                verifiedSegments: verifiedSegments,
                recordingStartTime: job.session.startedAt
            )
            return try transcriptionWorkItems(for: runs, verifiedSegments: verifiedSegments)
        case .automatic:
            return try await automaticTranscriptionWorkItems(
                verifiedSegments: verifiedSegments,
                job: job,
                configuration: automaticConfiguration
            )
        }
    }

    private func automaticTranscriptionWorkItems(
        verifiedSegments: [RecordingAudioStore.VerifiedSegment],
        job: Job,
        configuration: AutomaticTranscriptionConfiguration
    ) async throws -> [TranscriptionWorkItem] {
        var candidates: [BatchTranscriptionRunPlanner.Candidate] = []
        for (fileIndex, verified) in verifiedSegments.enumerated() {
            try await candidates.append(contentsOf: automaticCandidates(
                for: verified,
                fileIndex: fileIndex,
                configuration: configuration
            ))
        }
        let runs = BatchTranscriptionRunPlanner.runs(
            candidates: candidates,
            recordingStartTime: job.session.startedAt
        )
        return try transcriptionWorkItems(for: runs, verifiedSegments: verifiedSegments)
    }

    private func transcriptionWorkItems(
        for runs: [BatchTranscriptionRun],
        verifiedSegments: [RecordingAudioStore.VerifiedSegment]
    ) throws -> [TranscriptionWorkItem] {
        var workItems = runs.enumerated().map { index, run in
            TranscriptionWorkItem(
                index: index,
                fileIndices: run.fileIndices,
                request: .run(run)
            )
        }
        let coveredFileIndices = Set(runs.flatMap(\.fileIndices))
        for (fileIndex, verified) in verifiedSegments.enumerated()
            where !coveredFileIndices.contains(fileIndex) {
            guard let localeIdentifier = verified.ranges.first?.localeIdentifier,
                  !localeIdentifier.isEmpty else {
                throw BatchSpeechTranscriberError.invalidAudioRange
            }
            workItems.append(TranscriptionWorkItem(
                index: workItems.count,
                fileIndices: [fileIndex],
                request: .noAudio(localeIdentifier: localeIdentifier)
            ))
        }
        return workItems
    }

    private func automaticCandidates(
        for verified: RecordingAudioStore.VerifiedSegment,
        fileIndex: Int,
        configuration: AutomaticTranscriptionConfiguration
    ) async throws -> [BatchTranscriptionRunPlanner.Candidate] {
        let audioFormat = try AVAudioFile(forReading: verified.url).processingFormat
        guard audioFormat.sampleRate > 0 else {
            throw BatchSpeechTranscriberError.invalidAudioRange
        }
        let ranges = try BatchTranscriptionAudioRangePlanner.ranges(for: verified, mode: .automatic)
        var candidates: [BatchTranscriptionRunPlanner.Candidate] = []
        for range in ranges {
            guard range.startFrame >= 0, range.frameCount >= 0 else {
                throw BatchSpeechTranscriberError.invalidAudioRange
            }
            guard range.frameCount > 0 else { continue }
            let request = BatchSpeechTranscriptionRequest(
                audioURL: verified.url,
                startFrame: range.startFrame,
                frameCount: range.frameCount,
                recordedLocaleIdentifiers: range.recordedLocaleIdentifiers,
                supportedLocales: configuration.supportedLocales,
                automaticLanguageCandidateLocales: configuration.candidateLocales,
                allowedLanguageIdentifiers: configuration.allowedLanguageIdentifiers
            )
            let resolution = try await BatchSpeechTranscriberService.resolveLocale(
                for: request,
                languageDetector: configuration.languageDetector,
                onLanguageFallback: configuration.onLanguageFallback
            )
            candidates.append(BatchTranscriptionRunPlanner.Candidate(
                slice: BatchSpeechAudioSlice(
                    audioURL: verified.url,
                    startFrame: range.startFrame,
                    frameCount: range.frameCount
                ),
                localeIdentifier: resolution.locale.identifier,
                source: verified.segment.source,
                recordingSessionId: verified.segment.recordingSessionId,
                sessionOffsetSeconds: range.sessionOffsetSeconds,
                audioFormat: audioFormat,
                fileIndex: fileIndex
            ))
        }
        return candidates
    }
}
