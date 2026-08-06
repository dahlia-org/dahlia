import Foundation

extension BatchTranscriptionCoordinator {
    func processAudio(job: Job) async throws -> BatchProcessingOutput {
        let translationConfiguration = await MainActor.run {
            TranslationConfiguration(
                isEnabled: AppSettings.shared.transcriptTranslationEnabled,
                targetLanguage: AppSettings.shared.transcriptTranslationTargetLanguage
            )
        }

        guard let recordingAudioStore else {
            throw RecordingAudioStoreError.storageUnavailable
        }
        let speakerIdentificationEnabled = await speakerIdentificationEnabledProvider()
        return try await recordingAudioStore.withVerifiedTranscribableSegments(sessionId: job.session.id) { verified in
            let transcriptSegments = try await self.transcribe(
                verifiedSegments: verified,
                job: job,
                translationConfiguration: translationConfiguration
            )
            guard speakerIdentificationEnabled else {
                return BatchProcessingOutput(
                    transcriptSegments: transcriptSegments,
                    speakerAnalysis: nil,
                    transcriptSpeakerAssignments: [:]
                )
            }
            let speakerAnalysis = await self.speakerAnalyzerFactory().analyze(
                verifiedSegments: verified,
                recordingStartTime: job.session.startedAt
            )
            return BatchProcessingOutput(
                transcriptSegments: transcriptSegments,
                speakerAnalysis: speakerAnalysis,
                transcriptSpeakerAssignments: Self.mapSpeakers(
                    to: transcriptSegments,
                    analysis: speakerAnalysis,
                    recordingStartTime: job.session.startedAt
                )
            )
        }
    }

    static func mapSpeakers(
        to transcriptSegments: [TranscriptSegment],
        analysis: BatchProcessingOutput.SpeakerAnalysis,
        recordingStartTime: Date
    ) -> [UUID: UUID] {
        let speakersBySource = Dictionary(grouping: analysis.sources, by: \.audioSource)
            .mapValues { $0.flatMap(\.speakers) }
        var assignments: [UUID: UUID] = [:]
        for segment in transcriptSegments {
            guard let source = RecordingAudioSource(speakerLabel: segment.speakerLabel),
                  let speakers = speakersBySource[source] else { continue }
            let start = max(0, segment.startTime.timeIntervalSince(recordingStartTime))
            let end = max(start, segment.endTime?.timeIntervalSince(recordingStartTime) ?? start)
            let match = speakers.compactMap { speaker -> (UUID, Double)? in
                let overlap = speaker.spans.reduce(0.0) { total, span in
                    total + max(0, min(end, span.endTimeSeconds) - max(start, span.startTimeSeconds))
                }
                let containsStart = speaker.spans.contains {
                    $0.startTimeSeconds <= start && start < $0.endTimeSeconds
                }
                guard overlap > 0 || (end == start && containsStart) else { return nil }
                return (speaker.id, overlap)
            }.max { lhs, rhs in
                lhs.1 == rhs.1 ? lhs.0.uuidString > rhs.0.uuidString : lhs.1 < rhs.1
            }
            assignments[segment.id] = match?.0
        }
        return assignments
    }
}
