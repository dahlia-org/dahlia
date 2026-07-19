#if canImport(Testing)
    import Foundation
    @testable import Dahlia

    actor ControlledCodexChatMarkdownRenderer: CodexChatMarkdownRendering {
        private var requests: [String] = []
        private var cachedMarkdown: [String] = []
        private var continuations: [String: CheckedContinuation<[CodexChatMarkdownRenderedBlock], Never>] = [:]

        func blocks(
            for markdown: String,
            cacheResult _: Bool
        ) async -> [CodexChatMarkdownRenderedBlock] {
            requests.append(markdown)
            return await withCheckedContinuation { continuation in
                continuations[markdown] = continuation
            }
        }

        func cache(
            _: [CodexChatMarkdownRenderedBlock],
            for markdown: String
        ) {
            cachedMarkdown.append(markdown)
        }

        func complete(_ markdown: String) {
            continuations.removeValue(forKey: markdown)?.resume(
                returning: [.paragraph(AttributedString(markdown))]
            )
        }

        func requestedMarkdown() -> [String] {
            requests
        }

        func cachedValues() -> [String] {
            cachedMarkdown
        }
    }
#endif
