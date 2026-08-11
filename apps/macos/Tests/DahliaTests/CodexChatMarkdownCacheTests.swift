#if canImport(Testing)
    import Foundation
    import Testing
    @testable import Dahlia

    struct CodexChatMarkdownCacheTests {
        @Test func doesNotCacheStreamingProjections() async throws {
            let cache = CodexChatMarkdownCache(capacity: 2)
            let renderer = CodexChatMarkdownRenderer(cache: cache)

            _ = try await renderer.blocks(for: "**partial", cacheResult: false)

            #expect(await cache.cachedEntryCount() == 0)
        }

        @Test func keepsCompletedProjectionCacheCountBounded() async throws {
            let cache = CodexChatMarkdownCache(capacity: 2)
            let renderer = CodexChatMarkdownRenderer(cache: cache)

            _ = try await renderer.blocks(for: "first", cacheResult: true)
            _ = try await renderer.blocks(for: "second", cacheResult: true)
            _ = try await renderer.blocks(for: "third", cacheResult: true)

            #expect(await cache.cachedEntryCount() == 2)
        }

        @Test func keepsCompletedProjectionCacheCostBounded() async {
            let cache = CodexChatMarkdownCache(capacity: 10, maximumCost: 8)
            let blocks: [CodexChatMarkdownRenderedBlock] = [.paragraph(AttributedString("value"))]
            let result = CodexChatMarkdownRenderResult(
                blocks: blocks,
                stablePrefixBlockCount: 0,
                reparseSource: "value"
            )

            await cache.insert(result, for: "1234")
            await cache.insert(result, for: "5678")
            await cache.insert(result, for: "oversized")

            #expect(await cache.cachedEntryCount() == 2)
            #expect(await cache.cachedCost() == 8)
            #expect(await cache.result(for: "oversized") == nil)
        }
    }
#endif
