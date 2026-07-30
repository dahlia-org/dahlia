import Foundation

extension BatchTranscriptionCoordinator {
    enum TranscriptionRequest: Sendable {
        case automatic(BatchSpeechTranscriptionRequest)
        case manual(BatchManualTranscriptionRun)
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
        supportedLocales: [Locale],
        automaticLanguageCandidateLocales: [Locale]?,
        automaticLanguageCandidates: BatchLanguageDetectionCandidateSnapshot?
    ) throws -> [TranscriptionWorkItem] {
        switch job.session.batchLanguageDetectionMode {
        case .manual:
            let runs = try BatchManualTranscriptionRunPlanner.runs(
                verifiedSegments: verifiedSegments,
                recordingStartTime: job.session.startedAt
            )
            var workItems = runs.enumerated().map { index, run in
                TranscriptionWorkItem(
                    index: index,
                    fileIndices: run.fileIndices,
                    request: .manual(run)
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
        case .automatic:
            return try automaticTranscriptionWorkItems(
                verifiedSegments: verifiedSegments,
                job: job,
                supportedLocales: supportedLocales,
                automaticLanguageCandidateLocales: automaticLanguageCandidateLocales,
                automaticLanguageCandidates: automaticLanguageCandidates
            )
        }
    }

    private func automaticTranscriptionWorkItems(
        verifiedSegments: [RecordingAudioStore.VerifiedSegment],
        job: Job,
        supportedLocales: [Locale],
        automaticLanguageCandidateLocales: [Locale]?,
        automaticLanguageCandidates: BatchLanguageDetectionCandidateSnapshot?
    ) throws -> [TranscriptionWorkItem] {
        var workItems: [TranscriptionWorkItem] = []
        for (fileIndex, verified) in verifiedSegments.enumerated() {
            let ranges = try BatchTranscriptionAudioRangePlanner.ranges(
                for: verified,
                mode: .automatic
            )
            for range in ranges {
                workItems.append(
                    TranscriptionWorkItem(
                        index: workItems.count,
                        fileIndices: [fileIndex],
                        request: .automatic(BatchSpeechTranscriptionRequest(
                            audioURL: verified.url,
                            startFrame: range.startFrame,
                            frameCount: range.frameCount,
                            recordedLocaleIdentifiers: range.recordedLocaleIdentifiers,
                            languageDetectionMode: .automatic,
                            supportedLocales: supportedLocales,
                            automaticLanguageCandidateLocales: automaticLanguageCandidateLocales,
                            allowedLanguageIdentifiers: automaticLanguageCandidates?.identifierSet,
                            source: verified.segment.source,
                            recordingSessionId: job.session.id,
                            recordingStartTime: job.session.startedAt,
                            sessionOffsetSeconds: range.sessionOffsetSeconds
                        ))
                    )
                )
            }
        }
        return workItems
    }
}
