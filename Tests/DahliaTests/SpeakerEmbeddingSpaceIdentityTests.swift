import FluidAudio
import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct SpeakerEmbeddingSpaceIdentityTests {
        @Test
        func derivesRuntimeConfigurationIdentity() async throws {
            let rootURL = FileManager.default.temporaryDirectory.appending(
                path: "dahlia-speaker-space-\(UUID.v7().uuidString)",
                directoryHint: .isDirectory
            )
            defer { try? FileManager.default.removeItem(at: rootURL) }
            let manager = try SpeakerModelAssetManager(managedRootURL: rootURL)
            let configuration = FluidAudioSpeakerEmbeddingExtractor.diarizationConfiguration()

            let space = await manager.embeddingSpace()

            #expect(space.sampleRate == configuration.segmentation.sampleRate)
            #expect(space.excludesOverlap == configuration.embedding.excludeOverlap)
            #expect(space.preprocessing == SpeakerModelAssetManager.preprocessingDescriptor(configuration: configuration))

            var changedConfiguration = configuration
            changedConfiguration.segmentation.sampleRate = 8000
            #expect(
                SpeakerModelAssetManager.preprocessingDescriptor(configuration: changedConfiguration)
                    != space.preprocessing
            )
        }

        @Test
        func everyEmbeddingPipelineKnobChangesSpaceIdentity() async throws {
            let rootURL = FileManager.default.temporaryDirectory.appending(
                path: "dahlia-speaker-space-knobs-\(UUID.v7().uuidString)",
                directoryHint: .isDirectory
            )
            defer { try? FileManager.default.removeItem(at: rootURL) }
            let manager = try SpeakerModelAssetManager(managedRootURL: rootURL)
            let baselineConfiguration = FluidAudioSpeakerEmbeddingExtractor.diarizationConfiguration()
            let baseline = await manager.embeddingSpace(configuration: baselineConfiguration)

            var stepRatio = baselineConfiguration
            stepRatio.segmentation.stepRatio = 0.05
            var windowDuration = baselineConfiguration
            windowDuration.segmentation.windowDurationSeconds = 5
            var minimumOnDuration = baselineConfiguration
            minimumOnDuration.segmentation.minDurationOn = 0.5
            var minimumSegmentDuration = baselineConfiguration
            minimumSegmentDuration.embedding.minSegmentDurationSeconds = 0.3
            var skipStrategy = baselineConfiguration
            skipStrategy.embedding.skipStrategy = .maskSimilarity(threshold: 0.95)
            var clusteringThreshold = baselineConfiguration
            clusteringThreshold.clustering.threshold = 0.3

            let changedSpaces = await [
                manager.embeddingSpace(configuration: stepRatio),
                manager.embeddingSpace(configuration: windowDuration),
                manager.embeddingSpace(configuration: minimumOnDuration),
                manager.embeddingSpace(configuration: minimumSegmentDuration),
                manager.embeddingSpace(configuration: skipStrategy),
                manager.embeddingSpace(configuration: clusteringThreshold),
            ]
            #expect(changedSpaces.allSatisfy { $0 != baseline })
            #expect(Set(changedSpaces).count == changedSpaces.count)
        }

        @Test
        func pipelineDescriptorIsByteStableForSameConfiguration() {
            let configuration = FluidAudioSpeakerEmbeddingExtractor.diarizationConfiguration()

            let first = SpeakerModelAssetManager.preprocessingDescriptor(configuration: configuration)
            let second = SpeakerModelAssetManager.preprocessingDescriptor(configuration: configuration)

            #expect(Data(first.utf8) == Data(second.utf8))
            #expect(
                first == "community-1 mono Float32 16000Hz "
                    + "pipeline-sha256:940b0cc57514e75db9733e5ba3fce2699974b7815cdcc3781fd9d90ad813f300"
            )
        }

        @Test
        func fluidAudioVersionMatchesDependencyPins() throws {
            let repositoryRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let data = try Data(contentsOf: repositoryRoot.appending(path: "Package.resolved"))
            let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let pins = try #require(json["pins"] as? [[String: Any]])
            let fluidAudio = try #require(pins.first { $0["identity"] as? String == "fluidaudio" })
            let state = try #require(fluidAudio["state"] as? [String: Any])
            let resolvedVersion = try #require(state["version"] as? String)
            let packageSource = try String(
                contentsOf: repositoryRoot.appending(path: "Package.swift"),
                encoding: .utf8
            )
            let versionPattern = #"FluidAudio\.git", exact: "([^"]+)""#
            let expression = try NSRegularExpression(pattern: versionPattern)
            let sourceRange = NSRange(packageSource.startIndex..., in: packageSource)
            let match = try #require(expression.firstMatch(in: packageSource, range: sourceRange))
            let pinnedVersionRange = try #require(Range(match.range(at: 1), in: packageSource))
            let pinnedVersion = String(packageSource[pinnedVersionRange])

            #expect(SpeakerModelAssetManager.fluidAudioVersion == resolvedVersion)
            #expect(SpeakerModelAssetManager.fluidAudioVersion == pinnedVersion)
        }
    }
#endif
