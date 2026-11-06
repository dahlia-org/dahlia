import CoreGraphics
import DahliaRuntimeSupport
import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct ScreenshotAnalysisServiceTests {
        @Test
        func analysisAndSummarySendStoredImageBytes() async throws {
            let context = try #require(CGContext(
                data: nil, width: 2560, height: 1280, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            let image = try #require(context.makeImage())
            let data = try #require(ImageEncoder.encode(image))
            let meetingID = UUID.v7()
            let screenshotID = UUID.v7()
            let analysis = try await CodexScreenshotAnalysisService.codexInputs(for: [
                ScreenshotAnalysisInput(id: screenshotID, imageData: data, mimeType: "image/webp", runtimeProvider: .local),
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
                #expect(Data(base64Encoded: String(payload)) == data)
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
                        runtimeProvider: .local
                    ),
                ])
            }
            preparation.cancel()

            await #expect(throws: CancellationError.self) {
                _ = try await preparation.value
            }
        }

        @Test(arguments: [
            (CodexRuntimeProvider.local, nil as String?, "openai/gpt-6-luna", nil as String?),
            (.databricks(connectionID: .v7()), nil, "databricks/system.ai.gpt-6-luna", nil),
            (.dahlia(connectionID: .v7()), nil, "dahlia/gpt-6-luna", nil),
            (.local, "openai/gpt-5.6-luna", "openai/gpt-5.6-luna", "high"),
            (.dahlia(connectionID: .v7()), "dahlia/gpt-6-sol", "dahlia/gpt-6-sol", "high"),
        ])
        func sendsOneStructuredLunaRequestForOneScreenshot(
            provider: CodexRuntimeProvider,
            configuredModel: String?,
            expectedModel: String,
            effort: String?
        ) async throws {
            let screenshotID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
            let response = """
            {"screenshots":[
              {"screenshot_id":"\(screenshotID)","ocr_text":"Visible text","caption":"Visible caption"}
            ]}
            """
            let models = [expectedModel, "\(expectedModel.split(separator: "/")[0])/other-model"].map { reference in
                let parts = reference.split(separator: "/", maxSplits: 1).map(String.init)
                return TestPiTransport.model(provider: parts[0], id: parts[1])
            }
            let log = TestPiTransportLog()
            let pi = TestPiRuntime.generating(provider: provider, models: models.reversed(), reply: response, log: log)
            let analyzer = CodexScreenshotAnalysisService(appServer: pi.service)
            let input = ScreenshotAnalysisInput(
                id: screenshotID,
                imageData: Data([1]),
                mimeType: "image/png",
                runtimeProvider: provider, outputLanguage: .en, model: configuredModel,
                reasoningEffort: effort
            )

            let results = try await analyzer.analyze([input])

            #expect(results.map(\.screenshotID) == [screenshotID])
            #expect(results.map(\.ocrText) == ["Visible text"])
            #expect(results.map(\.caption) == ["Visible caption"])
            _ = try await analyzer.analyze([input])
            #expect(pi.launches.all.count(where: { $0.mode == .control }) == 1)
            #expect(pi.argument(after: "--model") == expectedModel)
            #expect(pi.argument(after: "--thinking") == effort ?? "low")
            let instructions = try #require(pi.argument(after: "--system-prompt"))
            #expect(instructions.contains("in English."))
            #expect(instructions.contains("in its original language"))
            #expect(!instructions.contains("Expected text languages"))
            #expect(instructions.contains(#""required":["screenshots"]"#))
            let prompt = await log.all.last?.command("prompt")
            #expect(prompt?["images"]?.arrayValue?.count == 1)
        }

        @Test
        func dropsControlCharactersAndTerminalEscapesFromDegenerateOutput() async throws {
            let screenshotID = UUID.v7()
            let response = #"""
            {"screenshots":[{"screenshot_id":"\#(screenshotID)",
              "ocr_text":"Maps\n\u0007\n\u001b[0m\n\u001b[0m\n","caption":"A \u0013browser\nwindow"}]}
            """#
            let pi = TestPiRuntime.generating(models: [TestPiTransport.model(provider: "openai", id: "gpt-6-luna")], reply: response)

            let results = try await CodexScreenshotAnalysisService(appServer: pi.service).analyze([
                ScreenshotAnalysisInput(id: screenshotID, imageData: Data([1]), mimeType: "image/png", runtimeProvider: .local),
            ])

            #expect(results == [ScreenshotAnalysis(screenshotID: screenshotID, ocrText: "Maps", caption: "A browser window")])
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
                        runtimeProvider: .local
                    ),
                    ScreenshotAnalysisInput(
                        id: .v7(),
                        imageData: Data([2]),
                        mimeType: "image/png",
                        runtimeProvider: .local
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
            let pi = TestPiRuntime.generating(models: [TestPiTransport.model(provider: "openai", id: "gpt-6-luna")], reply: response)
            let analyzer = CodexScreenshotAnalysisService(appServer: pi.service)

            await #expect(throws: ScreenshotAnalysisError.invalidResponse) {
                _ = try await analyzer.analyze([
                    ScreenshotAnalysisInput(
                        id: screenshotID,
                        imageData: Data([1]),
                        mimeType: "image/png",
                        runtimeProvider: .local
                    ),
                ])
            }
        }
    }
#endif
