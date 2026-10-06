import CoreGraphics
import DahliaRuntimeSupport
import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct SummaryScreenshotSelectionTests {
        private static func screenshots(_ count: Int) throws -> [MeetingScreenshotRecord] {
            let context = try #require(CGContext(
                data: nil, width: 1568, height: 980, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            let image = try #require(context.makeImage())
            let data = try #require(ImageEncoder.encode(image))
            let meetingID = UUID.v7()
            let start = Date(timeIntervalSince1970: 1_000)
            return (0 ..< count).map {
                .init(id: .v7(), meetingId: meetingID, capturedAt: start.addingTimeInterval(Double($0) * 30), imageData: data, mimeType: "image/webp")
            }
        }

        private static func settings(enabled: Bool = true) -> WorkspaceGenerationSettings {
            var settings = WorkspaceGenerationSettings()
            settings.imageAnalysis.enabled = enabled
            settings.imageAnalysis.model = "ignored-analysis-model"
            settings.screenshotSelection = .init(model: "selection-model", reasoningEffort: "high")
            return settings
        }

        @Test
        func sendsLowResolutionCandidatesWithTheSelectionModelAndKeepsCaptureOrder() async throws {
            let candidates = try Self.screenshots(3)
            let transport = TestCodexAppServerTransport(
                mode: .generationCompletes, modelName: "selection-model", generationResponse: #"{"indices":[3,1,3]}"#
            )
            let appServer = makeTestCodexAppServerService(transportFactory: { transport })

            let selected = try await SummaryScreenshotSelection.select(
                candidates, settings: Self.settings(), runtimeProvider: .chatGPTSubscription, appServer: appServer
            )

            #expect(selected.map(\.id) == [candidates[0].id, candidates[2].id])
            let messages = await transport.messages()
            let thread = try #require(messages.first { $0.objectValue?["method"]?.stringValue == "thread/start" }?.objectValue?["params"]?.objectValue)
            #expect(thread["model"] == .string("selection-model"))
            #expect(thread["config"]?.objectValue?["model_reasoning_effort"] == .string("high"))
            let input = try #require(messages.first { $0.objectValue?["method"]?.stringValue == "turn/start" }?
                .objectValue?["params"]?.objectValue?["input"]?.arrayValue)
            #expect(input.count == 6)
            #expect(input.compactMap { $0.objectValue?["text"]?.stringValue }.last == #"<image index="3" elapsed_seconds="60"/>"#)
            let uris = input.compactMap { $0.objectValue?["url"]?.stringValue }
            #expect(uris.count == 3)
            let uri = try #require(uris.first)
            let base64 = try #require(uri.split(separator: ",", maxSplits: 1).last)
            let payload = try #require(Data(base64Encoded: String(base64)))
            let size = try #require(ImageEncoder.pixelSize(of: payload))
            #expect(max(size.width, size.height) <= 480)
            await appServer.shutdown()
        }

        @Test
        func disabledImageAnalysisAndInvalidSelectionKeepEveryCandidate() async throws {
            let candidates = try Self.screenshots(2)
            for (enabled, response) in [(false, #"{"indices":[1]}"#), (true, #"{"indices":[3]}"#)] {
                let transport = TestCodexAppServerTransport(mode: .generationCompletes, modelName: "selection-model", generationResponse: response)
                let appServer = makeTestCodexAppServerService(transportFactory: { transport })
                let selected = try await SummaryScreenshotSelection.select(
                    candidates, settings: Self.settings(enabled: enabled), runtimeProvider: .chatGPTSubscription, appServer: appServer
                )
                #expect(selected.map(\.id) == candidates.map(\.id))
                #expect(await transport.messages().isEmpty == !enabled)
                await appServer.shutdown()
            }
        }

        @Test
        func stalledSelectionKeepsEveryCandidateAfterTheTimeLimit() async throws {
            let candidates = try Self.screenshots(2)
            let transport = TestCodexAppServerTransport(mode: .generationBlocks, modelName: "selection-model")
            let appServer = makeTestCodexAppServerService(transportFactory: { transport })

            let selected = try await SummaryScreenshotSelection.select(
                candidates, settings: Self.settings(), runtimeProvider: .chatGPTSubscription, appServer: appServer,
                timeout: .milliseconds(200)
            )

            #expect(selected.map(\.id) == candidates.map(\.id))
            await appServer.shutdown()
        }

        @Test
        func cancellingTheSummaryCancelsSelectionAndInterruptsTheTurn() async throws {
            let candidates = try Self.screenshots(2)
            let transport = TestCodexAppServerTransport(mode: .generationBlocks, modelName: "selection-model")
            let appServer = makeTestCodexAppServerService(transportFactory: { transport })
            let selection = Task {
                try await SummaryScreenshotSelection.select(
                    candidates, settings: Self.settings(), runtimeProvider: .chatGPTSubscription, appServer: appServer
                )
            }

            try await appServer.waitUntilActiveTurnCountForTesting(1)
            selection.cancel()

            await #expect(throws: CancellationError.self) { _ = try await selection.value }
            await transport.waitUntilSent("turn/interrupt")
            await appServer.shutdown()
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
