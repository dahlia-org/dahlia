@preconcurrency import AVFoundation
import FluidAudio
import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct SpeakerEmbeddingExtractorTests {
        @Test
        func chunkValidationEnforcesDimensionFiniteValuesAndUnitNormTolerance() {
            #expect(SpeakerEmbeddingValidation.normalizedChunk([Float](repeating: 0, count: 255)) == nil)

            var nonFinite = unitVector(index: 0)
            nonFinite[3] = .nan
            #expect(SpeakerEmbeddingValidation.normalizedChunk(nonFinite) == nil)

            let exact = SpeakerEmbeddingValidation.normalizedChunk(unitVector(index: 5))
            #expect(exact == unitVector(index: 5))

            var withinTolerance = unitVector(index: 7)
            withinTolerance[7] = 1.02
            let renormalized = SpeakerEmbeddingValidation.normalizedChunk(withinTolerance)
            #expect(abs((renormalized?[7] ?? 0) - 1) < 0.000_001)

            var outsideTolerance = unitVector(index: 9)
            outsideTolerance[9] = 1.051
            #expect(SpeakerEmbeddingValidation.normalizedChunk(outsideTolerance) == nil)
        }

        @Test
        func speakerDatabaseAcceptsAndRenormalizesAnUnnormalizedMean() {
            var databaseValue = unitVector(index: 12)
            databaseValue[12] = 4

            let normalized = SpeakerEmbeddingValidation.normalizedSpeakerDatabaseValue(databaseValue)

            #expect(abs((normalized?[12] ?? 0) - 1) < 0.000_001)
        }

        @Test
        func representativeIsQualityWeightedNormalizedMean() async throws {
            let output = SpeakerDiarizationOutput(
                chunks: [
                    chunk(speakerID: "S1", embedding: unitVector(index: 0), duration: 1),
                    chunk(speakerID: "S1", embedding: unitVector(index: 1), duration: 3),
                ],
                speakerDatabase: [:]
            )
            let evidence = try await extract(output: output)
            let representative = try #require(evidence.first?.representative.values)
            let denominator = Float(sqrt(10.0))

            #expect(abs(representative[0] - 1 / denominator) < 0.000_001)
            #expect(abs(representative[1] - 3 / denominator) < 0.000_001)
            #expect(abs(l2Norm(representative) - 1) < 0.000_001)
        }

        @Test
        func qualityPolicyIsTheOnlyPersistedEvidenceFilter() async throws {
            let policy = SpeakerEmbeddingQualityPolicy(
                minimumSegmentDurationSeconds: 1,
                minimumRMS: 0.1,
                maximumClippingRatio: 0.05,
                minimumSegmentQuality: 0.6
            )
            let output = SpeakerDiarizationOutput(
                chunks: [
                    chunk(speakerID: "S1", embedding: unitVector(index: 0)),
                    chunk(speakerID: "S1", embedding: unitVector(index: 1), duration: 0.9),
                    chunk(speakerID: "S1", embedding: unitVector(index: 2), rms: 0.09),
                    chunk(speakerID: "S1", embedding: unitVector(index: 3), clippingRatio: 0.051),
                    chunk(speakerID: "S1", embedding: unitVector(index: 4), segmentQuality: 0.59),
                ],
                speakerDatabase: [:]
            )

            let evidence = try await extract(output: output, qualityPolicy: policy)

            #expect(evidence.first?.exemplars.count == 1)
            #expect(evidence.first?.representative.values == unitVector(index: 0))
        }

        @Test
        func meetingExemplarsAreCappedAtThreeClosestValidChunks() async throws {
            let angles = [-20.0, 90.0, 10.0, -90.0, 0.0]
            let embeddings = angles.map { angle -> [Float] in
                var embedding = [Float](repeating: 0, count: 256)
                let radians = angle * .pi / 180
                embedding[0] = Float(cos(radians))
                embedding[1] = Float(sin(radians))
                return embedding
            }
            let output = SpeakerDiarizationOutput(
                chunks: embeddings.map { embedding in
                    chunk(speakerID: "S1", embedding: embedding)
                },
                speakerDatabase: [:]
            )

            let evidence = try await extract(output: output)
            let exemplars = try #require(evidence.first?.exemplars.map(\.values))
            let exemplarIdentities = exemplars.map { exemplar in
                Int((atan2(Double(exemplar[1]), Double(exemplar[0])) * 180 / .pi).rounded())
            }

            #expect(exemplarIdentities == [0, 10, -20])
            #expect(evidence.first?.profileUpdateEligible == true)
        }

        @Test
        func validationRejectsCosineSimilarityAcrossDifferentDimensions() {
            #expect(
                SpeakerEmbeddingValidation.cosineSimilarity(
                    unitVector(index: 0),
                    [Float](repeating: 0, count: 255)
                ) == .unknown(.invalidEmbedding)
            )
        }

        @Test
        func speakerDatabaseOnlyEvidenceIsDisplayFallbackAndCannotUpdateProfile() async throws {
            var databaseValue = unitVector(index: 20)
            databaseValue[20] = 3
            let output = SpeakerDiarizationOutput(
                chunks: [],
                speakerDatabase: ["S2": databaseValue]
            )

            let evidence = try await extract(output: output)

            #expect(evidence.first?.speakerID == "S2")
            #expect(evidence.first?.representative.values == unitVector(index: 20))
            #expect(evidence.first?.exemplars.isEmpty == true)
            #expect(evidence.first?.profileUpdateEligible == false)
        }

        @Test
        func inconsistentSpeakerDatabaseDisablesLearningWithoutReplacingChunkRepresentative() async throws {
            let output = SpeakerDiarizationOutput(
                chunks: [chunk(speakerID: "S1", embedding: unitVector(index: 0))],
                speakerDatabase: ["S1": unitVector(index: 1)]
            )

            let evidence = try await extract(output: output)

            #expect(evidence.first?.representative.values == unitVector(index: 0))
            #expect(evidence.first?.exemplars.isEmpty == true)
            #expect(evidence.first?.profileUpdateEligible == false)
        }

        @Test
        func wholeEmbeddingSpaceIdentityMustMatchBeforeComparison() {
            let first = SpeakerEmbedding(space: space(), values: unitVector(index: 0))
            let matching = SpeakerEmbedding(space: space(), values: unitVector(index: 0))
            let mismatched = SpeakerEmbedding(
                space: space(revision: "different-revision"),
                values: unitVector(index: 0)
            )

            #expect(first.cosineSimilarity(to: matching) == .candidate(score: 1))
            #expect(first.cosineSimilarity(to: mismatched) == .unknown(.incompatibleEmbeddingSpace))
        }

        @Test
        func descriptionsRedactEmbeddingsPersonCandidatesAndScores() throws {
            let embedding = SpeakerEmbedding(
                space: space(),
                values: [0.123_456_7] + [Float](repeating: 0, count: 255)
            )
            let personID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
            let evidence = MeetingSpeakerEvidence(
                speakerID: "S1",
                representative: embedding,
                exemplars: [embedding],
                profileUpdateEligible: true
            )
            let result = SpeakerMatchResult.matched(personID: personID, score: 0.765_432_1)
            let chunk = chunk(speakerID: "S1", embedding: embedding.values)
            let output = SpeakerDiarizationOutput(
                chunks: [chunk],
                speakerDatabase: ["S1": embedding.values]
            )
            let payload = [
                embedding.description,
                String(reflecting: embedding),
                evidence.description,
                String(reflecting: evidence),
                String(reflecting: [evidence]),
                result.description,
                String(reflecting: result),
                chunk.description,
                String(reflecting: chunk),
                output.description,
                String(reflecting: output),
            ].joined(separator: " ")

            #expect(!payload.contains("0.1234567"))
            #expect(!payload.contains("0.7654321"))
            #expect(!payload.contains(personID.uuidString))
            #expect(payload.contains("<redacted>"))
        }

        @Test
        func onlyUserConfirmedAssignmentOriginsAreLearnable() {
            #expect(SpeakerAssignmentOrigin.manual.isLearnable)
            #expect(SpeakerAssignmentOrigin.suggestionApproved.isLearnable)
            #expect(!SpeakerAssignmentOrigin.ownerChannelConfirmation.isLearnable)
        }

        @Test
        func fluidConfigurationUsesCommunityEmbeddingDefaultsAndExposesChunks() {
            let configuration = FluidAudioSpeakerEmbeddingExtractor.diarizationConfiguration()

            #expect(configuration.embedding.excludeOverlap)
            #expect(configuration.exposeChunkEmbeddings)
            #expect(configuration.embedding.minSegmentDurationSeconds == 1.0)
        }
    }

    @Suite(.serialized)
    struct SpeakerAudioSampleSourceTests {
        @Test
        func convertsSourcesSeparatelyAndPreservesSessionTimelineGaps() async throws {
            let directory = FileManager.default.temporaryDirectory.appending(
                path: "dahlia-speaker-audio-tests-\(UUID.v7().uuidString)",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let firstMicURL = directory.appending(path: "mic-first.caf")
            let secondMicURL = directory.appending(path: "mic-second.caf")
            let systemURL = directory.appending(path: "system.caf")
            try writeAudioFile(firstMicURL, sampleRate: 48000, channels: 2, duration: 0.1, amplitude: 0.2)
            try writeAudioFile(secondMicURL, sampleRate: 44100, channels: 1, duration: 0.1, amplitude: 0.3)
            try writeAudioFile(systemURL, sampleRate: 32000, channels: 2, duration: 0.1, amplitude: 0.6)
            let converter = SpeakerAudioSampleSourceConverter(temporaryDirectoryURL: directory)

            let sources = try await converter.convert([
                slice(source: .microphone, url: firstMicURL, sampleRate: 48000, offset: 0.25),
                slice(source: .microphone, url: secondMicURL, sampleRate: 44100, offset: 0.5),
                slice(source: .system, url: systemURL, sampleRate: 32000, offset: 0.1),
            ])
            let microphone = try #require(sources[.microphone])
            let system = try #require(sources[.system])
            defer {
                try? microphone.cleanup()
                try? system.cleanup()
            }
            let microphoneSamples = try samples(from: microphone)
            let systemSamples = try samples(from: system)

            #expect(microphone.sampleRate == 16000)
            #expect(system.sampleRate == 16000)
            #expect(microphoneSamples.count >= 9400)
            #expect(systemSamples.count >= 3000)
            #expect(window(microphoneSamples, start: 0, count: 4000).allSatisfy { $0 == 0 })
            #expect(meanAbsolute(window(microphoneSamples, start: 4100, count: 1300)) > 0.05)
            #expect(window(microphoneSamples, start: 5700, count: 2200).allSatisfy { $0 == 0 })
            #expect(meanAbsolute(window(microphoneSamples, start: 8100, count: 1300)) > 0.1)
            #expect(window(systemSamples, start: 0, count: 1600).allSatisfy { $0 == 0 })
            #expect(meanAbsolute(window(systemSamples, start: 1700, count: 1300)) > 0.2)
            #expect(microphone.temporaryFileURL != system.temporaryFileURL)
        }

        @Test
        func temporaryFileCleanupIsExplicitAndTestable() async throws {
            let directory = FileManager.default.temporaryDirectory.appending(
                path: "dahlia-speaker-cleanup-tests-\(UUID.v7().uuidString)",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let inputURL = directory.appending(path: "input.caf")
            try writeAudioFile(inputURL, sampleRate: 16000, channels: 1, duration: 0.1, amplitude: 0.2)
            let converter = SpeakerAudioSampleSourceConverter(temporaryDirectoryURL: directory)
            let sources = try await converter.convert([
                slice(source: .microphone, url: inputURL, sampleRate: 16000, offset: 0),
            ])
            let source = try #require(sources[.microphone])

            #expect(FileManager.default.fileExists(atPath: source.temporaryFileURL.path))
            try source.cleanup()
            #expect(!FileManager.default.fileExists(atPath: source.temporaryFileURL.path))
        }

        @Test
        func conversionFailureRemovesAlreadyCreatedTemporarySources() async throws {
            let directory = FileManager.default.temporaryDirectory.appending(
                path: "dahlia-speaker-failure-tests-\(UUID.v7().uuidString)",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let microphoneURL = directory.appending(path: "microphone.caf")
            try writeAudioFile(microphoneURL, sampleRate: 16000, channels: 1, duration: 0.1, amplitude: 0.2)
            let missingSystemURL = directory.appending(path: "missing-system.caf")
            let converter = SpeakerAudioSampleSourceConverter(temporaryDirectoryURL: directory)

            await #expect(throws: (any Error).self) {
                try await converter.convert([
                    slice(source: .microphone, url: microphoneURL, sampleRate: 16000, offset: 0),
                    slice(source: .system, url: missingSystemURL, sampleRate: 16000, offset: 0),
                ])
            }

            let temporarySources = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "f32" }
            #expect(temporarySources.isEmpty)
        }
    }

    private actor StaticSpeakerDiarizationProcessor: SpeakerDiarizationProcessing {
        let output: SpeakerDiarizationOutput

        init(output: SpeakerDiarizationOutput) {
            self.output = output
        }

        func process(source _: MemoryMappedAudioSampleSource) -> SpeakerDiarizationOutput {
            output
        }
    }

    private func extract(
        output: SpeakerDiarizationOutput,
        qualityPolicy: SpeakerEmbeddingQualityPolicy = .production
    ) async throws -> [MeetingSpeakerEvidence] {
        let temporaryURL = FileManager.default.temporaryDirectory.appending(
            path: "dahlia-speaker-empty-\(UUID.v7().uuidString).f32"
        )
        try Data().write(to: temporaryURL)
        let source = try MemoryMappedAudioSampleSource(temporaryFileURL: temporaryURL)
        defer { try? source.cleanup() }
        let extractor = FluidAudioSpeakerEmbeddingExtractor(
            processor: StaticSpeakerDiarizationProcessor(output: output),
            space: space(),
            qualityPolicy: qualityPolicy
        )
        return try await extractor.extract(from: source)
    }

    private func chunk(
        speakerID: String,
        embedding: [Float],
        duration: Double = 1.5,
        rms: Float = 0.5,
        clippingRatio: Float = 0,
        segmentQuality: Float = 1
    ) -> SpeakerEmbeddingChunk {
        SpeakerEmbeddingChunk(
            speakerID: speakerID,
            startTimeSeconds: 0,
            endTimeSeconds: duration,
            durationSeconds: duration,
            embedding: embedding,
            rms: rms,
            clippingRatio: clippingRatio,
            segmentQuality: segmentQuality
        )
    }

    private func unitVector(index: Int) -> [Float] {
        var values = [Float](repeating: 0, count: 256)
        values[index] = 1
        return values
    }

    private func l2Norm(_ values: [Float]) -> Float {
        sqrt(values.reduce(0) { $0 + $1 * $1 })
    }

    private func space(revision: String = "revision") -> SpeakerEmbeddingSpace {
        SpeakerEmbeddingSpace(
            provider: "provider",
            modelName: "model",
            revision: revision,
            assetFingerprint: "fingerprint",
            fluidAudioVersion: "0.15.5",
            dimensionCount: 256,
            sampleRate: 16000,
            preprocessing: "mono",
            excludesOverlap: true,
            normalization: "L2",
            similarityDefinition: "cosine"
        )
    }

    private func writeAudioFile(
        _ url: URL,
        sampleRate: Double,
        channels: AVAudioChannelCount,
        duration: Double,
        amplitude: Float
    ) throws {
        let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: channels
        )!
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        for channel in 0 ..< Int(channels) {
            let samples = buffer.floatChannelData![channel]
            for frame in 0 ..< Int(frameCount) {
                samples[frame] = amplitude
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private func slice(
        source: RecordingAudioSource,
        url: URL,
        sampleRate: Double,
        offset: TimeInterval
    ) -> SpeakerAudioFileSlice {
        SpeakerAudioFileSlice(
            source: source,
            url: url,
            startFrame: 0,
            frameCount: Int64(sampleRate * 0.1),
            sessionOffsetSeconds: offset
        )
    }

    private func samples(from source: MemoryMappedAudioSampleSource) throws -> [Float] {
        var result = [Float](repeating: 0, count: source.sampleCount)
        try result.withUnsafeMutableBufferPointer { pointer in
            try source.copySamples(into: pointer.baseAddress!, offset: 0, count: pointer.count)
        }
        return result
    }

    private func window(_ samples: [Float], start: Int, count: Int) -> ArraySlice<Float> {
        samples.dropFirst(start).prefix(count)
    }

    private func meanAbsolute(_ samples: ArraySlice<Float>) -> Float {
        samples.reduce(0) { $0 + abs($1) } / Float(samples.count)
    }
#endif
