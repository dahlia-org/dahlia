import CoreGraphics
import DahliaRuntimeSupport
import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct ScreenshotAnalysisServiceTests {
        @Test
        func analysisAndSummaryUse1280PixelImages() async throws {
            let context = try #require(CGContext(
                data: nil, width: 2560, height: 1280, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            let image = try #require(context.makeImage())
            let data = try #require(ImageEncoder.encode(image))
            let meetingID = UUID.v7()
            let screenshotID = UUID.v7()
            let analysis = try await CodexScreenshotAnalysisService.codexInputs(for: [
                ScreenshotAnalysisInput(id: screenshotID, imageData: data, mimeType: "image/webp", runtimeProvider: .chatGPTSubscription),
            ])
            let summary = try await SummaryService.makeCodexInputs(.init(
                promptContext: .init(meetingId: meetingID, recordedAt: .now, calendarEvent: nil, projectName: nil, projectDescription: nil),
                transcriptText: "Transcript", noteText: nil,
                screenshots: [.init(id: screenshotID, meetingId: meetingID, capturedAt: .now, imageData: data, mimeType: "image/webp")],
                recordingSessions: []
            ))
            for inputs in [analysis, summary] {
                let images = inputs.compactMap { input -> String? in
                    if case let .imageDataURI(uri) = input { return uri }
                    return nil
                }
                #expect(images.count == 1)
                let uri = try #require(images.first)
                let payload = try #require(uri.split(separator: ",", maxSplits: 1).last)
                let bytes = try #require(Data(base64Encoded: String(payload)))
                let decoded = try #require(CGImageDecoder.decode(bytes))
                #expect(decoded.width == 1280)
                #expect(decoded.height == 640)
            }
        }

        @Test
        func cancelledImagePreparationStopsBeforeEncoding() async {
            let preparation = Task {
                while !Task.isCancelled {
                    await Task.yield()
                }
                return try await CodexScreenshotAnalysisService.codexInputs(for: [
                    ScreenshotAnalysisInput(
                        id: .v7(),
                        imageData: Data([1]),
                        mimeType: "image/png",
                        runtimeProvider: .chatGPTSubscription
                    ),
                ])
            }
            preparation.cancel()

            await #expect(throws: CancellationError.self) {
                _ = try await preparation.value
            }
        }

        @Test(arguments: [
            (CodexRuntimeProvider.chatGPTSubscription, "gpt-5.6-luna"),
            (.databricks(profile: "test"), "gpt-5.6-luna"),
            (.dahlia(connectionID: UUID.v7()), "gpt-5-6-luna"),
        ])
        func sendsOneStructuredLunaRequestForOneScreenshot(
            provider: CodexRuntimeProvider,
            expectedModel: String
        ) async throws {
            let screenshotID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
            let response = """
            {"screenshots":[
              {"screenshot_id":"\(screenshotID)","ocr_text":"Visible text","caption":"Visible caption"}
            ]}
            """
            let transport = TestCodexAppServerTransport(
                mode: .generationCompletes,
                modelName: expectedModel,
                generationResponse: response
            )
            let appServer = makeTestCodexAppServerService(
                transportFactory: { transport },
                runtimeProviderResolver: { provider }
            )
            let analyzer = CodexScreenshotAnalysisService(appServer: appServer)

            let results = try await analyzer.analyze([
                ScreenshotAnalysisInput(
                    id: screenshotID,
                    imageData: Data([1]),
                    mimeType: "image/png",
                    runtimeProvider: provider
                ),
            ])

            #expect(results.map(\.screenshotID) == [screenshotID])
            #expect(results.map(\.ocrText) == ["Visible text"])
            #expect(results.map(\.caption) == ["Visible caption"])
            _ = try await analyzer.analyze([
                ScreenshotAnalysisInput(
                    id: screenshotID,
                    imageData: Data([1]),
                    mimeType: "image/png",
                    runtimeProvider: provider
                ),
            ])
            let messages = await transport.messages()
            #expect(messages.count(where: { $0.objectValue?["method"]?.stringValue == "model/list" }) == 1)
            let threadParams = try #require(messages.first {
                $0.objectValue?["method"]?.stringValue == "thread/start"
            }?.objectValue?["params"]?.objectValue)
            #expect(threadParams["model"] == .string(expectedModel))
            #expect(threadParams["config"]?.objectValue?["model_reasoning_effort"] == .string("low"))
            let turnParams = try #require(messages.first {
                $0.objectValue?["method"]?.stringValue == "turn/start"
            }?.objectValue?["params"]?.objectValue)
            #expect(turnParams["input"]?.arrayValue?.count == 2)
            #expect(turnParams["outputSchema"]?.objectValue?["required"] == .array([.string("screenshots")]))
            await appServer.shutdown()
        }

        @Test
        func rejectsMultipleScreenshots() async {
            let analyzer = CodexScreenshotAnalysisService()

            await #expect(throws: ScreenshotAnalysisError.invalidBatchSize) {
                _ = try await analyzer.analyze([
                    ScreenshotAnalysisInput(
                        id: .v7(),
                        imageData: Data([1]),
                        mimeType: "image/png",
                        runtimeProvider: .chatGPTSubscription
                    ),
                    ScreenshotAnalysisInput(
                        id: .v7(),
                        imageData: Data([2]),
                        mimeType: "image/png",
                        runtimeProvider: .chatGPTSubscription
                    ),
                ])
            }
        }

        @Test
        func rejectsCaptionThatBecomesEmptyAfterNormalization() async throws {
            let screenshotID = UUID.v7()
            let response = """
            {"screenshots":[
              {"screenshot_id":"\(screenshotID)","ocr_text":"Visible text","caption":"   "}
            ]}
            """
            let transport = TestCodexAppServerTransport(
                mode: .generationCompletes,
                modelName: CodexScreenshotAnalysisService.model,
                generationResponse: response
            )
            let appServer = makeTestCodexAppServerService(transportFactory: { transport })
            let analyzer = CodexScreenshotAnalysisService(appServer: appServer)

            await #expect(throws: ScreenshotAnalysisError.invalidResponse) {
                _ = try await analyzer.analyze([
                    ScreenshotAnalysisInput(
                        id: screenshotID,
                        imageData: Data([1]),
                        mimeType: "image/png",
                        runtimeProvider: .chatGPTSubscription
                    ),
                ])
            }
            await appServer.shutdown()
        }
    }
#endif
