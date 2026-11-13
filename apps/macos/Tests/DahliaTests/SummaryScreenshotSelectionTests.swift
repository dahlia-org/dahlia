import CoreGraphics
import DahliaRuntimeSupport
import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct SummaryScreenshotSelectionTests {
        @Test
        func invalidSelectionTriesTheImageFallbackBeforeKeepingAllCandidates() async throws {
            let candidates = try Self.screenshots(2)
            var settings = Self.settings()
            settings.imageAnalysis.fallbackModel = "openai/fallback"
            let pi = TestPiRuntime.generating(
                models: Self.models + [TestPiTransport.model(provider: "openai", id: "fallback")],
                replyForModel: { $0 == "openai/selection-model" ? #"{"indices":[999]}"# : #"{"indices":[2]}"# }
            )

            let selected = try await SummaryScreenshotSelection.select(
                candidates, settings: settings, runtimeProvider: .local, appServer: pi.service
            )

            #expect(selected.map(\.id) == [candidates[1].id])
            #expect(pi.launches.all.count(where: { $0.mode == .summary }) == 2)
            #expect(pi.argument(after: "--model") == "openai/fallback")
            #expect(pi.argument(after: "--thinking") == "medium")
        }

        private static func screenshots(_ count: Int) throws -> [MeetingScreenshotRecord] {
            let context = try #require(CGContext(
                data: nil, width: 1568, height: 980, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            let image = try #require(context.makeImage())
            let data = try #require(ImageEncoder.encode(image))
            let meetingID = UUID.v7()
            let start = Date(timeIntervalSince1970: 1000)
            return (0 ..< count).map {
                .init(id: .v7(), meetingId: meetingID, capturedAt: start.addingTimeInterval(Double($0) * 30), imageData: data, mimeType: "image/webp")
            }
        }

        private static func settings(enabled: Bool = true) -> WorkspaceGenerationSettings {
            var settings = WorkspaceGenerationSettings()
            settings.imageAnalysis.enabled = enabled
            settings.imageAnalysis.model = "selection-model"
            settings.imageAnalysis.reasoningEffort = "high"
            return settings
        }

        private static let models = [
            TestPiTransport.model(provider: "openai", id: "other"),
            TestPiTransport.model(provider: "openai", id: "selection-model"),
        ]

        /// Lists models, then accepts the prompt without ever finishing the run.
        private static func stalled(log: TestPiTransportLog) -> TestPiRuntime {
            TestPiRuntime { options in
                let transport = options.mode == .control ? TestPiTransport(reply: TestPiRuntime.modelsReply(models)) : TestPiTransport()
                log.append(transport)
                return transport
            }
        }

        @Test
        func sendsLowResolutionCandidatesWithTheSelectionModelAndKeepsCaptureOrder() async throws {
            let candidates = try Self.screenshots(3)
            let log = TestPiTransportLog()
            let pi = TestPiRuntime.generating(models: Self.models, reply: #"{"indices":[3,1,3]}"#, log: log)

            let selected = try await SummaryScreenshotSelection.select(
                candidates, settings: Self.settings(), runtimeProvider: .local, appServer: pi.service
            )

            #expect(selected.map(\.id) == [candidates[0].id, candidates[2].id])
            #expect(pi.argument(after: "--model") == "openai/selection-model")
            // A saved effort from an earlier release is ignored.
            #expect(pi.argument(after: "--thinking") == "medium")
            let prompt = try #require(await log.all.last?.command("prompt"))
            #expect(prompt["message"]?.stringValue?.hasSuffix(#"[Attached image 3] <image index="3" elapsed_seconds="60"/>"#) == true)
            let images = try #require(prompt["images"]?.arrayValue)
            #expect(images.count == 3)
            let payload = try #require(Data(base64Encoded: images[0].objectValue?["data"]?.stringValue ?? ""))
            let size = try #require(ImageEncoder.pixelSize(of: payload))
            #expect(max(size.width, size.height) <= 480)
        }

        @Test
        func imageSearchDisabledStillSelectsAndInvalidSelectionKeepsEveryCandidate() async throws {
            let candidates = try Self.screenshots(2)
            for (enabled, response) in [(false, #"{"indices":[1]}"#), (true, #"{"indices":[3]}"#)] {
                let pi = TestPiRuntime.generating(models: Self.models, reply: response)
                let selected = try await SummaryScreenshotSelection.select(
                    candidates, settings: Self.settings(enabled: enabled), runtimeProvider: .local, appServer: pi.service
                )
                #expect(selected.map(\.id) == (enabled ? candidates.map(\.id) : [candidates[0].id]))
                #expect(pi.launches.all.contains { $0.mode == .summary })
            }
        }

        @Test
        func stalledSelectionKeepsEveryCandidateAfterTheTimeLimit() async throws {
            let candidates = try Self.screenshots(2)
            let log = TestPiTransportLog()
            let pi = Self.stalled(log: log)

            let selected = try await SummaryScreenshotSelection.select(
                candidates, settings: Self.settings(), runtimeProvider: .local, appServer: pi.service,
                timeout: .milliseconds(200)
            )

            #expect(selected.map(\.id) == candidates.map(\.id))
            #expect(await log.allClosed())
        }

        @Test
        func cancellingTheSummaryCancelsSelectionAndStopsPi() async throws {
            let candidates = try Self.screenshots(2)
            let log = TestPiTransportLog()
            let pi = Self.stalled(log: log)
            let selection = Task {
                try await SummaryScreenshotSelection.select(
                    candidates, settings: Self.settings(), runtimeProvider: .local, appServer: pi.service
                )
            }

            let summary = await log.transport(at: 1)
            _ = await summary.command("prompt")
            selection.cancel()

            await #expect(throws: CancellationError.self) { _ = try await selection.value }
            #expect(await summary.isClosed)
        }

        @Test
        func validatesIndicesAndSpreadsLargePoolsEvenly() throws {
            #expect(try SummaryScreenshotSelection.selectedIndices(#"{"indices":[]}"#, count: 2).isEmpty)
            #expect(try SummaryScreenshotSelection.selectedIndices(#"{"indices":[2,1]}"#, count: 2) == [0, 1])
            for response in [#"{"indices":[0]}"#, #"{"indices":"1"}"#, "{\"indices\":[\(Array(repeating: "1", count: 25).joined(separator: ","))]}"] {
                #expect(throws: (any Error).self) { try SummaryScreenshotSelection.selectedIndices(response, count: 30) }
            }
            let spread = SummaryScreenshotSelection.spreadEvenly(Array(0 ..< 500), limit: 240)
            #expect(spread.count == 240)
            #expect(spread.first == 0 && spread.last == 499)
            #expect(Set(spread).count == 240)
            #expect(SummaryScreenshotSelection.spreadEvenly([1, 2], limit: 240) == [1, 2])
        }
    }
#endif
