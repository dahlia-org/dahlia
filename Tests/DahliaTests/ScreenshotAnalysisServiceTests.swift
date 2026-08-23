import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct ScreenshotAnalysisServiceTests {
        @Test
        func cancelledImagePreparationStopsBeforeEncoding() async {
            let preparation = Task {
                while !Task.isCancelled {
                    await Task.yield()
                }
                return try await CodexScreenshotAnalysisService.codexInputs(for: [
                    ScreenshotAnalysisInput(id: .v7(), imageData: Data([1]), mimeType: "image/png"),
                ])
            }
            preparation.cancel()

            await #expect(throws: CancellationError.self) {
                _ = try await preparation.value
            }
        }

        @Test
        func sendsOneStructuredLunaRequestForTheBatch() async throws {
            let firstID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
            let secondID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
            let response = """
            {"screenshots":[
              {"screenshot_id":"\(firstID)","ocr_text":"First text","caption":"First caption"},
              {"screenshot_id":"\(secondID)","ocr_text":"Second text","caption":"Second caption"}
            ]}
            """
            let transport = TestCodexAppServerTransport(
                mode: .generationCompletes,
                modelName: CodexScreenshotAnalysisService.model,
                generationResponse: response
            )
            let appServer = makeTestCodexAppServerService(transportFactory: { transport })
            let analyzer = CodexScreenshotAnalysisService(appServer: appServer)

            let results = try await analyzer.analyze([
                ScreenshotAnalysisInput(id: firstID, imageData: Data([1]), mimeType: "image/png"),
                ScreenshotAnalysisInput(id: secondID, imageData: Data([2]), mimeType: "image/png"),
            ])

            #expect(results.map(\.screenshotID) == [firstID, secondID])
            #expect(results.map(\.caption) == ["First caption", "Second caption"])
            _ = try await analyzer.analyze([
                ScreenshotAnalysisInput(id: firstID, imageData: Data([1]), mimeType: "image/png"),
                ScreenshotAnalysisInput(id: secondID, imageData: Data([2]), mimeType: "image/png"),
            ])
            let messages = await transport.messages()
            #expect(messages.count(where: { $0.objectValue?["method"]?.stringValue == "model/list" }) == 1)
            let threadParams = try #require(messages.first {
                $0.objectValue?["method"]?.stringValue == "thread/start"
            }?.objectValue?["params"]?.objectValue)
            #expect(threadParams["model"] == .string(CodexScreenshotAnalysisService.model))
            #expect(threadParams["config"]?.objectValue?["model_reasoning_effort"] == .string("low"))
            let turnParams = try #require(messages.first {
                $0.objectValue?["method"]?.stringValue == "turn/start"
            }?.objectValue?["params"]?.objectValue)
            #expect(turnParams["input"]?.arrayValue?.count == 4)
            #expect(turnParams["outputSchema"]?.objectValue?["required"] == .array([.string("screenshots")]))
            await appServer.shutdown()
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
                    ScreenshotAnalysisInput(id: screenshotID, imageData: Data([1]), mimeType: "image/png"),
                ])
            }
            await appServer.shutdown()
        }
    }
#endif
