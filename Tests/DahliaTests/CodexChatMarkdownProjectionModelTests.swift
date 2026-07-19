#if canImport(Testing)
    import Testing
    @testable import Dahlia

    @MainActor
    struct CodexChatMarkdownProjectionModelTests {
        @Test func coalescesPendingInputsAndPublishesOnlyLatestProjection() async {
            let renderer = ControlledCodexChatMarkdownRenderer()
            let model = CodexChatMarkdownProjectionModel(renderer: renderer)

            model.submit(input("first"))
            await waitForRequest("first", renderer: renderer)
            model.submit(input("second"))
            model.submit(input("third"))

            #expect(await renderer.requestedMarkdown() == ["first"])
            await renderer.complete("first")
            await waitForRequest("third", renderer: renderer)
            #expect(await renderer.requestedMarkdown() == ["first", "third"])

            await renderer.complete("third")
            await waitForProjection("third", model: model)
            #expect(model.projection?.markdown == "third")
        }

        @Test func keepsAppendedRawSuffixVisibleWhileRendering() async {
            let renderer = ControlledCodexChatMarkdownRenderer()
            let model = CodexChatMarkdownProjectionModel(renderer: renderer)

            model.submit(input("rendered"))
            await waitForRequest("rendered", renderer: renderer)
            await renderer.complete("rendered")
            await waitForProjection("rendered", model: model)

            model.submit(input("rendered tail"))

            #expect(model.canDisplayProjection)
            #expect(model.pendingSuffix == " tail")
            model.cancel()
            await renderer.complete("rendered tail")
        }

        @Test func completionCachesExistingProjectionWithoutRenderingAgain() async {
            let renderer = ControlledCodexChatMarkdownRenderer()
            let model = CodexChatMarkdownProjectionModel(renderer: renderer)

            model.submit(input("complete"))
            await waitForRequest("complete", renderer: renderer)
            model.submit(CodexChatMarkdownInput(markdown: "complete", isStreaming: false))
            await renderer.complete("complete")
            await waitForProjection("complete", model: model)
            await waitForCachedValue("complete", renderer: renderer)

            #expect(await renderer.requestedMarkdown() == ["complete"])
        }

        @Test func nonPrefixReplacementFallsBackToRawMarkdown() async {
            let renderer = ControlledCodexChatMarkdownRenderer()
            let model = CodexChatMarkdownProjectionModel(renderer: renderer)

            model.submit(input("original"))
            await waitForRequest("original", renderer: renderer)
            await renderer.complete("original")
            await waitForProjection("original", model: model)

            model.submit(input("replacement"))

            #expect(!model.canDisplayProjection)
            #expect(model.pendingSuffix == nil)
            model.cancel()
            await renderer.complete("replacement")
        }

        @Test func cancelledRenderCannotPublish() async {
            let renderer = ControlledCodexChatMarkdownRenderer()
            let model = CodexChatMarkdownProjectionModel(renderer: renderer)

            model.submit(input("cancelled"))
            await waitForRequest("cancelled", renderer: renderer)
            model.cancel()
            await renderer.complete("cancelled")
            await Task.yield()

            #expect(model.projection == nil)
        }

        private func input(_ markdown: String) -> CodexChatMarkdownInput {
            CodexChatMarkdownInput(markdown: markdown, isStreaming: true)
        }

        private func waitForRequest(
            _ markdown: String,
            renderer: ControlledCodexChatMarkdownRenderer
        ) async {
            for _ in 0 ..< 1_000 {
                if await renderer.requestedMarkdown().contains(markdown) {
                    return
                }
                await Task.yield()
            }
            Issue.record("Renderer did not receive \(markdown)")
        }

        private func waitForProjection(
            _ markdown: String,
            model: CodexChatMarkdownProjectionModel
        ) async {
            for _ in 0 ..< 1_000 {
                if model.projection?.markdown == markdown {
                    return
                }
                await Task.yield()
            }
            Issue.record("Projection did not publish \(markdown)")
        }

        private func waitForCachedValue(
            _ markdown: String,
            renderer: ControlledCodexChatMarkdownRenderer
        ) async {
            for _ in 0 ..< 1_000 {
                if await renderer.cachedValues().contains(markdown) {
                    return
                }
                await Task.yield()
            }
            Issue.record("Renderer did not cache \(markdown)")
        }
    }
#endif
