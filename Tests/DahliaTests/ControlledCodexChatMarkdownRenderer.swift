#if canImport(Testing)
    import Foundation
    @testable import Dahlia

    actor ControlledCodexChatMarkdownRenderer: CodexChatMarkdownRendering {
        private var requests: [String] = []
        private var pendingRequests: [PendingRequest] = []
        private var cachedMarkdown: [String] = []
        private var continuations: [String: CheckedContinuation<CodexChatMarkdownRenderResult, Never>] = [:]
        private var pendingContinuations: [PendingRequest: CheckedContinuation<[CodexChatMarkdownRenderedBlock], Never>] = [:]

        func blocks(
            for markdown: String,
            cacheResult _: Bool
        ) async -> CodexChatMarkdownRenderResult {
            requests.append(markdown)
            return await withCheckedContinuation { continuation in
                continuations[markdown] = continuation
            }
        }

        func pendingBlocks(
            reparseSource: String,
            suffix: String
        ) async -> [CodexChatMarkdownRenderedBlock] {
            let request = PendingRequest(reparseSource: reparseSource, suffix: suffix)
            pendingRequests.append(request)
            return await withCheckedContinuation { continuation in
                pendingContinuations[request] = continuation
            }
        }

        func cache(
            _: CodexChatMarkdownRenderResult,
            for markdown: String
        ) {
            cachedMarkdown.append(markdown)
        }

        func complete(_ markdown: String) {
            let parsed = try? CodexChatMarkdownParser.parseTrackingUnstableTail(markdown)
            let rendered = parsed.flatMap { try? CodexChatMarkdownBlockRenderer.render($0.blocks) }
            continuations.removeValue(forKey: markdown)?.resume(returning: CodexChatMarkdownRenderResult(
                blocks: rendered ?? [],
                stablePrefixBlockCount: parsed?.stablePrefixBlockCount ?? 0,
                reparseSource: parsed?.reparseSource ?? markdown
            ))
        }

        func completePending(
            reparseSource: String,
            suffix: String
        ) {
            let request = PendingRequest(reparseSource: reparseSource, suffix: suffix)
            let parsed = try? CodexChatMarkdownParser.parse(reparseSource + suffix)
            let rendered = parsed.flatMap { try? CodexChatMarkdownBlockRenderer.render($0) }
            pendingContinuations.removeValue(forKey: request)?.resume(returning: rendered ?? [])
        }

        func requestedMarkdown() -> [String] {
            requests
        }

        func requestedPendingInputs() -> [PendingRequest] {
            pendingRequests
        }

        func cachedValues() -> [String] {
            cachedMarkdown
        }

        struct PendingRequest: Equatable, Hashable, Sendable {
            let reparseSource: String
            let suffix: String
        }
    }
#endif
