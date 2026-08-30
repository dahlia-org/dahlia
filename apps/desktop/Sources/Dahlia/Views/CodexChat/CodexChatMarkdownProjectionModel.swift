import Foundation
import Observation

@MainActor
@Observable
final class CodexChatMarkdownProjectionModel {
    private(set) var projection: CodexChatMarkdownProjection?
    private(set) var displayBlocks: [CodexChatMarkdownRenderedBlock]?
    private(set) var canDisplayProjection = false

    @ObservationIgnored private let renderer: any CodexChatMarkdownRendering
    @ObservationIgnored private var currentInput: CodexChatMarkdownInput?
    @ObservationIgnored private var pendingInput: CodexChatMarkdownInput?
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var pendingDisplayInput: DisplayInput?
    @ObservationIgnored private var displayTask: Task<Void, Never>?

    init(renderer: any CodexChatMarkdownRendering = CodexChatMarkdownRenderer()) {
        self.renderer = renderer
    }

    func submit(_ input: CodexChatMarkdownInput) {
        currentInput = input
        updateDisplay(for: input)

        if !input.isStreaming,
           let projection,
           projection.markdown == input.markdown {
            pendingInput = nil
            let renderer = renderer
            Task {
                await renderer.cache(projection.renderResult, for: input.markdown)
            }
            return
        }

        pendingInput = input
        startNextRenderIfNeeded()
    }

    func cancel() {
        currentInput = nil
        pendingInput = nil
        renderTask?.cancel()
        pendingDisplayInput = nil
        displayTask?.cancel()
    }

    private func startNextRenderIfNeeded() {
        guard renderTask == nil, let input = pendingInput else { return }
        pendingInput = nil
        let renderer = renderer

        renderTask = Task { [weak self] in
            let result = try? await renderer.blocks(
                for: input.markdown,
                cacheResult: !input.isStreaming
            )
            self?.finishRender(
                result: result,
                input: input
            )
        }
    }

    private func finishRender(
        result: CodexChatMarkdownRenderResult?,
        input: CodexChatMarkdownInput
    ) {
        renderTask = nil
        if let result,
           let currentInput,
           currentInput.markdown.hasPrefix(input.markdown) {
            projection = CodexChatMarkdownProjection(
                markdown: input.markdown,
                blocks: result.blocks,
                stablePrefixBlockCount: result.stablePrefixBlockCount,
                reparseSource: result.reparseSource
            )
            updateDisplay(for: currentInput)
            if !currentInput.isStreaming,
               currentInput.markdown == input.markdown {
                let renderer = renderer
                Task {
                    await renderer.cache(result, for: input.markdown)
                }
            }
            if pendingInput?.markdown == input.markdown {
                pendingInput = nil
            }
        }
        startNextRenderIfNeeded()
    }

    private func updateDisplay(for input: CodexChatMarkdownInput) {
        guard let projection,
              input.markdown.hasPrefix(projection.markdown)
        else {
            canDisplayProjection = false
            displayBlocks = nil
            pendingDisplayInput = nil
            displayTask?.cancel()
            return
        }

        canDisplayProjection = true
        let suffix = String(input.markdown.dropFirst(projection.markdown.count))
        guard !suffix.isEmpty else {
            pendingDisplayInput = nil
            displayBlocks = projection.blocks
            return
        }

        if displayBlocks == nil {
            displayBlocks = projection.blocks
        }
        pendingDisplayInput = DisplayInput(
            input: input,
            projection: projection,
            suffix: suffix
        )
        startNextDisplayIfNeeded()
    }

    private func startNextDisplayIfNeeded() {
        guard displayTask == nil, let displayInput = pendingDisplayInput else { return }
        pendingDisplayInput = nil
        let renderer = renderer

        displayTask = Task { [weak self] in
            let blocks = try? await renderer.pendingBlocks(
                reparseSource: displayInput.projection.reparseSource,
                suffix: displayInput.suffix
            )
            self?.finishDisplay(blocks: blocks, displayInput: displayInput)
        }
    }

    private func finishDisplay(
        blocks: [CodexChatMarkdownRenderedBlock]?,
        displayInput: DisplayInput
    ) {
        displayTask = nil
        if let blocks,
           currentInput == displayInput.input,
           projection == displayInput.projection {
            displayBlocks = Array(displayInput.projection.blocks.prefix(
                displayInput.projection.stablePrefixBlockCount
            )) + blocks
        }
        startNextDisplayIfNeeded()
    }

    private struct DisplayInput: Equatable, Sendable {
        let input: CodexChatMarkdownInput
        let projection: CodexChatMarkdownProjection
        let suffix: String
    }
}
