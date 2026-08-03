#if canImport(Testing)
    import Foundation
    import Testing
    @testable import Dahlia

    @MainActor
    // swiftlint:disable:next type_body_length
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

        @Test func rendersAppendedSuffixAsStyledBlocks() async {
            let renderer = ControlledCodexChatMarkdownRenderer()
            let model = CodexChatMarkdownProjectionModel(renderer: renderer)

            await prepareProjection("rendered", renderer: renderer, model: model)

            model.submit(input("rendered tail"))
            await waitForPendingRequest(
                reparseSource: "rendered",
                suffix: " tail",
                renderer: renderer
            )
            await renderer.completePending(reparseSource: "rendered", suffix: " tail")
            await waitForDisplayBlocks([.paragraph(AttributedString("rendered tail"))], model: model)

            #expect(model.canDisplayProjection)
            #expect(model.displayBlocks == [.paragraph(AttributedString("rendered tail"))])
            model.cancel()
            await renderer.complete("rendered tail")
        }

        @Test func rendersSuffixCrossingABlockBoundaryAsStyledBlocks() async {
            let renderer = ControlledCodexChatMarkdownRenderer()
            let model = CodexChatMarkdownProjectionModel(renderer: renderer)

            await prepareProjection("paragraph", renderer: renderer, model: model)

            model.submit(input("paragraph\n\n# Heading"))
            await waitForPendingRequest(
                reparseSource: "paragraph",
                suffix: "\n\n# Heading",
                renderer: renderer
            )
            await renderer.completePending(reparseSource: "paragraph", suffix: "\n\n# Heading")
            let expected: [CodexChatMarkdownRenderedBlock] = [
                .paragraph(AttributedString("paragraph")),
                .heading(level: 1, text: AttributedString("Heading")),
            ]
            await waitForDisplayBlocks(expected, model: model)

            #expect(model.canDisplayProjection)
            #expect(model.displayBlocks == expected)
            model.cancel()
            await renderer.complete("paragraph\n\n# Heading")
        }

        @Test func publishesCompletedPrefixRenderAfterInputAdvances() async {
            let renderer = ControlledCodexChatMarkdownRenderer()
            let model = CodexChatMarkdownProjectionModel(renderer: renderer)

            model.submit(input("Hello"))
            await waitForRequest("Hello", renderer: renderer)
            model.submit(input("Hello world"))
            await renderer.complete("Hello")
            await waitForProjection("Hello", model: model)
            await waitForPendingRequest(reparseSource: "Hello", suffix: " world", renderer: renderer)
            await renderer.completePending(reparseSource: "Hello", suffix: " world")
            await waitForDisplayBlocks([.paragraph(AttributedString("Hello world"))], model: model)

            #expect(model.canDisplayProjection)
            #expect(model.displayBlocks == [.paragraph(AttributedString("Hello world"))])
            model.cancel()
            await renderer.complete("Hello world")
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

            await prepareProjection("original", renderer: renderer, model: model)

            model.submit(input("replacement"))

            #expect(!model.canDisplayProjection)
            #expect(model.displayBlocks == nil)
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
            #expect(model.displayBlocks == nil)
        }

        @Test func pendingCodeBlockContainsAllVisibleCode() async {
            let renderer = ControlledCodexChatMarkdownRenderer()
            let model = CodexChatMarkdownProjectionModel(renderer: renderer)
            let base = "```swift\nlet a = 1"
            let suffix = "\nlet b = 2"

            await prepareProjection(base, renderer: renderer, model: model)
            model.submit(input(base + suffix))
            await waitForPendingRequest(reparseSource: base, suffix: suffix, renderer: renderer)
            await renderer.completePending(reparseSource: base, suffix: suffix)
            await waitForDisplayBlocks([
                .code(language: "swift", text: "let a = 1\nlet b = 2"),
            ], model: model)

            #expect(model.displayBlocks == [
                .code(language: "swift", text: "let a = 1\nlet b = 2"),
            ])
            model.cancel()
            await renderer.complete(base + suffix)
        }

        @Test func pendingFenceCanOpenCloseAndContinueWithParagraph() async {
            let renderer = ControlledCodexChatMarkdownRenderer()
            let model = CodexChatMarkdownProjectionModel(renderer: renderer)
            let base = "```"
            let suffix = "swift\nlet value = 1\n```\nAfter"

            await prepareProjection(base, renderer: renderer, model: model)
            model.submit(input(base + suffix))
            await waitForPendingRequest(reparseSource: base, suffix: suffix, renderer: renderer)
            await renderer.completePending(reparseSource: base, suffix: suffix)
            await waitForDisplayBlocks([
                .code(language: "swift", text: "let value = 1"),
                .paragraph(AttributedString("After")),
            ], model: model)

            model.cancel()
            await renderer.complete(base + suffix)
        }

        @Test func pendingDisplayCoalescesBurstToLatestInput() async {
            let renderer = ControlledCodexChatMarkdownRenderer()
            let model = CodexChatMarkdownProjectionModel(renderer: renderer)

            await prepareProjection("base", renderer: renderer, model: model)
            model.submit(input("base one"))
            await waitForPendingRequest(reparseSource: "base", suffix: " one", renderer: renderer)
            model.submit(input("base two"))
            model.submit(input("base three"))

            await renderer.completePending(reparseSource: "base", suffix: " one")
            await waitForPendingRequest(reparseSource: "base", suffix: " three", renderer: renderer)
            #expect(await renderer.requestedPendingInputs().map(\.suffix) == [" one", " three"])
            await renderer.completePending(reparseSource: "base", suffix: " three")
            await waitForDisplayBlocks([.paragraph(AttributedString("base three"))], model: model)

            model.cancel()
            for markdown in await renderer.requestedMarkdown() where markdown != "base" {
                await renderer.complete(markdown)
            }
        }

        @Test func baseProjectionPublishesWhilePendingRebuildIsBlocked() async {
            let renderer = ControlledCodexChatMarkdownRenderer()
            let model = CodexChatMarkdownProjectionModel(renderer: renderer)

            model.submit(input("base"))
            await waitForRequest("base", renderer: renderer)
            model.submit(input("base suffix"))
            await renderer.complete("base")
            await waitForProjection("base", model: model)
            await waitForPendingRequest(reparseSource: "base", suffix: " suffix", renderer: renderer)

            #expect(model.displayBlocks == [.paragraph(AttributedString("base"))])

            model.cancel()
            await renderer.completePending(reparseSource: "base", suffix: " suffix")
            await renderer.complete("base suffix")
        }

        @Test func stalePendingCompletionCannotPublishAfterReplacement() async {
            let renderer = ControlledCodexChatMarkdownRenderer()
            let model = CodexChatMarkdownProjectionModel(renderer: renderer)

            await prepareProjection("base", renderer: renderer, model: model)
            model.submit(input("base old"))
            await waitForPendingRequest(reparseSource: "base", suffix: " old", renderer: renderer)
            model.submit(input("replacement"))
            #expect(model.displayBlocks == nil)

            await renderer.completePending(reparseSource: "base", suffix: " old")
            await Task.yield()
            #expect(model.displayBlocks == nil)

            model.cancel()
            await renderer.complete("base old")
            await renderer.complete("replacement")
        }

        @Test func cancelledPendingRebuildCannotPublish() async {
            let renderer = ControlledCodexChatMarkdownRenderer()
            let model = CodexChatMarkdownProjectionModel(renderer: renderer)

            await prepareProjection("base", renderer: renderer, model: model)
            model.submit(input("base suffix"))
            await waitForPendingRequest(reparseSource: "base", suffix: " suffix", renderer: renderer)
            model.cancel()
            await renderer.completePending(reparseSource: "base", suffix: " suffix")
            await Task.yield()

            #expect(model.displayBlocks == [.paragraph(AttributedString("base"))])
            await renderer.complete("base suffix")
        }

        @Test func reparsesNewlineDividerAndTableTails() async {
            let cases: [(base: String, suffix: String, expected: [CodexChatMarkdownRenderedBlock])] = [
                (
                    "paragraph\n",
                    "\n# Heading",
                    [.paragraph(AttributedString("paragraph")), .heading(level: 1, text: AttributedString("Heading"))]
                ),
                (
                    "paragraph\n---",
                    "x",
                    [.paragraph(AttributedString("paragraph ---x"))]
                ),
                (
                    "| Name | Value |\n| --- | --- |",
                    "\n| one | 1 |",
                    [
                        .table(CodexChatMarkdownRenderedTable(
                            header: [AttributedString("Name"), AttributedString("Value")],
                            rows: [[AttributedString("one"), AttributedString("1")]],
                            alignments: [.left, .left]
                        )),
                    ]
                ),
            ]

            for testCase in cases {
                let renderer = ControlledCodexChatMarkdownRenderer()
                let model = CodexChatMarkdownProjectionModel(renderer: renderer)
                await prepareProjection(testCase.base, renderer: renderer, model: model)
                guard let projection = model.projection else {
                    Issue.record("Expected base projection")
                    continue
                }
                model.submit(input(testCase.base + testCase.suffix))
                await waitForPendingRequest(
                    reparseSource: projection.reparseSource,
                    suffix: testCase.suffix,
                    renderer: renderer
                )
                await renderer.completePending(
                    reparseSource: projection.reparseSource,
                    suffix: testCase.suffix
                )
                await waitForDisplayBlocks(testCase.expected, model: model)
                model.cancel()
                await renderer.complete(testCase.base + testCase.suffix)
            }
        }

        private func input(_ markdown: String) -> CodexChatMarkdownInput {
            CodexChatMarkdownInput(markdown: markdown, isStreaming: true)
        }

        private func prepareProjection(
            _ markdown: String,
            renderer: ControlledCodexChatMarkdownRenderer,
            model: CodexChatMarkdownProjectionModel
        ) async {
            model.submit(input(markdown))
            await waitForRequest(markdown, renderer: renderer)
            await renderer.complete(markdown)
            await waitForProjection(markdown, model: model)
        }

        private func waitForRequest(
            _ markdown: String,
            renderer: ControlledCodexChatMarkdownRenderer
        ) async {
            for _ in 0 ..< 1000 {
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
            for _ in 0 ..< 1000 {
                if model.projection?.markdown == markdown {
                    return
                }
                await Task.yield()
            }
            Issue.record("Projection did not publish \(markdown)")
        }

        private func waitForPendingRequest(
            reparseSource: String,
            suffix: String,
            renderer: ControlledCodexChatMarkdownRenderer
        ) async {
            for _ in 0 ..< 1000 {
                if await renderer.requestedPendingInputs().contains(.init(
                    reparseSource: reparseSource,
                    suffix: suffix
                )) {
                    return
                }
                await Task.yield()
            }
            Issue.record("Renderer did not receive pending suffix \(suffix)")
        }

        private func waitForDisplayBlocks(
            _ blocks: [CodexChatMarkdownRenderedBlock],
            model: CodexChatMarkdownProjectionModel
        ) async {
            for _ in 0 ..< 1000 {
                if model.displayBlocks == blocks {
                    return
                }
                await Task.yield()
            }
            Issue.record("Display blocks did not publish expected content")
        }

        private func waitForCachedValue(
            _ markdown: String,
            renderer: ControlledCodexChatMarkdownRenderer
        ) async {
            for _ in 0 ..< 1000 {
                if await renderer.cachedValues().contains(markdown) {
                    return
                }
                await Task.yield()
            }
            Issue.record("Renderer did not cache \(markdown)")
        }
    }
#endif
