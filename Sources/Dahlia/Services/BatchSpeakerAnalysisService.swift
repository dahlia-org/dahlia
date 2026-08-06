import Foundation

protocol BatchSpeakerAnalyzing: Sendable {
    func analyze(
        verifiedSegments: [RecordingAudioStore.VerifiedSegment],
        recordingStartTime: Date
    ) async -> BatchProcessingOutput.SpeakerAnalysis
}

actor BatchSpeakerAnalysisService: BatchSpeakerAnalyzing {
    typealias ExtractorFactory = @Sendable () throws -> any SpeakerEmbeddingExtractor

    private let converter: SpeakerAudioSampleSourceConverter
    private let extractorFactory: ExtractorFactory

    init(
        converter: SpeakerAudioSampleSourceConverter = SpeakerAudioSampleSourceConverter(),
        extractorFactory: @escaping ExtractorFactory = {
            try SpeakerDiarizationRuntime(assetManager: SpeakerModelAssetManager())
        }
    ) {
        self.converter = converter
        self.extractorFactory = extractorFactory
    }

    func analyze(
        verifiedSegments: [RecordingAudioStore.VerifiedSegment],
        recordingStartTime _: Date
    ) async -> BatchProcessingOutput.SpeakerAnalysis {
        let audioSources = Set(verifiedSegments.map(\.segment.source))
        let slices = verifiedSegments.flatMap { verified in
            verified.ranges.compactMap { range -> SpeakerAudioFileSlice? in
                guard let frameCount = range.frameCount else { return nil }
                return SpeakerAudioFileSlice(
                    source: verified.segment.source,
                    url: verified.url,
                    startFrame: range.startFrame,
                    frameCount: frameCount,
                    sessionOffsetSeconds: range.sessionOffsetSeconds
                )
            }
        }

        let sampleSources: [RecordingAudioSource: MemoryMappedAudioSampleSource]
        do {
            sampleSources = try await converter.convert(slices)
        } catch {
            return failedAnalysis(for: audioSources, reason: .analysisFailed)
        }
        defer {
            for source in sampleSources.values {
                try? source.cleanup()
            }
        }

        let extractor: any SpeakerEmbeddingExtractor
        do {
            extractor = try extractorFactory()
        } catch {
            return failedAnalysis(for: audioSources, reason: .analysisFailed)
        }

        var analyses: [BatchProcessingOutput.SourceAnalysis] = []
        for audioSource in audioSources.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let sampleSource = sampleSources[audioSource] else {
                analyses.append(failedSource(audioSource, reason: .insufficientEvidence))
                continue
            }
            do {
                let extraction = try await extractor.analyze(from: sampleSource)
                guard let embeddingSpace = extraction.embeddingSpace,
                      !extraction.speakers.isEmpty else {
                    analyses.append(failedSource(audioSource, reason: .insufficientEvidence))
                    continue
                }
                analyses.append(successfulSource(
                    audioSource,
                    extraction: extraction,
                    embeddingSpace: embeddingSpace
                ))
            } catch is CancellationError {
                analyses.append(failedSource(audioSource, reason: .analysisFailed))
            } catch {
                analyses.append(failedSource(audioSource, reason: .analysisFailed))
            }
        }
        return BatchProcessingOutput.SpeakerAnalysis(sources: analyses)
    }

    private func successfulSource(
        _ audioSource: RecordingAudioSource,
        extraction: SpeakerAnalysisExtraction,
        embeddingSpace: SpeakerEmbeddingSpace
    ) -> BatchProcessingOutput.SourceAnalysis {
        let speakers = extraction.speakers.map { evidence in
            let spans = Set(extraction.spans.filter {
                $0.speakerID == evidence.speakerID
                    && $0.startTimeSeconds.isFinite
                    && $0.endTimeSeconds.isFinite
                    && $0.startTimeSeconds >= 0
                    && $0.endTimeSeconds > $0.startTimeSeconds
            }).sorted {
                $0.startTimeSeconds == $1.startTimeSeconds
                    ? $0.endTimeSeconds < $1.endTimeSeconds
                    : $0.startTimeSeconds < $1.startTimeSeconds
            }
            return BatchProcessingOutput.Speaker(
                id: .v7(),
                localSpeakerId: evidence.speakerID,
                representative: evidence.representative,
                representativeSource: evidence.representativeSource,
                profileUpdateEligible: evidence.profileUpdateEligible,
                exemplars: Array(evidence.exemplars.prefix(3)),
                spans: spans
            )
        }
        return BatchProcessingOutput.SourceAnalysis(
            id: .v7(),
            audioSource: audioSource,
            embeddingSpace: embeddingSpace,
            speakers: speakers,
            failureReason: nil
        )
    }

    private func failedAnalysis(
        for audioSources: Set<RecordingAudioSource>,
        reason: SpeakerMatchUnknownReason
    ) -> BatchProcessingOutput.SpeakerAnalysis {
        BatchProcessingOutput.SpeakerAnalysis(
            sources: audioSources
                .sorted { $0.rawValue < $1.rawValue }
                .map { failedSource($0, reason: reason) }
        )
    }

    private func failedSource(
        _ audioSource: RecordingAudioSource,
        reason: SpeakerMatchUnknownReason
    ) -> BatchProcessingOutput.SourceAnalysis {
        BatchProcessingOutput.SourceAnalysis(
            id: .v7(),
            audioSource: audioSource,
            embeddingSpace: nil,
            speakers: [],
            failureReason: reason
        )
    }
}
