import Foundation
import Observation

@MainActor
@Observable
final class CodexChatMarkdownProjectionModel {
    private(set) var projection: CodexChatMarkdownProjection?
    private(set) var pendingSuffix: String?
    private(set) var canDisplayProjection = false

    @ObservationIgnored private let renderer: any CodexChatMarkdownRendering
    @ObservationIgnored private var currentInput: CodexChatMarkdownInput?
    @ObservationIgnored private var pendingInput: CodexChatMarkdownInput?
    @ObservationIgnored private var renderTask: Task<Void, Never>?

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
                await renderer.cache(projection.blocks, for: input.markdown)
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
    }

    private func startNextRenderIfNeeded() {
        guard renderTask == nil, let input = pendingInput else { return }
        pendingInput = nil
        let renderer = renderer

        renderTask = Task { [weak self] in
            let blocks = try? await renderer.blocks(
                for: input.markdown,
                cacheResult: !input.isStreaming
            )
            self?.finishRender(
                blocks: blocks,
                input: input
            )
        }
    }

    private func finishRender(
        blocks: [CodexChatMarkdownRenderedBlock]?,
        input: CodexChatMarkdownInput
    ) {
        renderTask = nil
        if let blocks,
           let currentInput,
           currentInput.markdown == input.markdown {
            projection = CodexChatMarkdownProjection(markdown: input.markdown, blocks: blocks)
            updateDisplay(for: currentInput)
            if !currentInput.isStreaming {
                let renderer = renderer
                Task {
                    await renderer.cache(blocks, for: input.markdown)
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
            pendingSuffix = nil
            return
        }

        canDisplayProjection = true
        let suffix = String(input.markdown.dropFirst(projection.markdown.count))
        pendingSuffix = suffix.nilIfBlank == nil ? nil : suffix
    }
}
