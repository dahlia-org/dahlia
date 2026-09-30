#if canImport(Testing)
    import Foundation
    import Testing
    @testable import Dahlia

    struct SyncTransferSlotsTests {
        private actor Gate {
            let entered: AsyncStream<String>
            private let events: AsyncStream<String>.Continuation
            private var held: [String: CheckedContinuation<Void, Never>] = [:]
            init() { (entered, events) = AsyncStream.makeStream() }
            func hold(_ name: String) async {
                await withCheckedContinuation { continuation in
                    held[name] = continuation
                    events.yield(name)
                }
            }

            func release(_ name: String) { held.removeValue(forKey: name)?.resume() }
            func releaseAll() { for continuation in held.values {
                continuation.resume()
            }
            held.removeAll()
            }
        }

        @Test(.timeLimit(.minutes(1))) func backgroundLeavesOnePermitForCurrentWork() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let slots = SyncTransferSlots.shared(dbQueue: database.dbQueue)
            #expect(slots === SyncTransferSlots.shared(dbQueue: database.dbQueue))
            let gate = Gate()
            var entries = await gate.entered.makeAsyncIterator()
            let background = (0 ..< 4).map { index in
                Task { try await slots.perform(background: true) { await gate.hold("background-\(index)") } }
            }
            var admitted: [String] = []
            for _ in 0 ..< 3 {
                try admitted.append(#require(await entries.next()))
            }
            let foreground = Task { try await slots.perform(background: false) { await gate.hold("foreground") } }
            #expect(await entries.next() == "foreground")
            await gate.release(admitted[0])
            #expect(try #require(await entries.next()).hasPrefix("background-"))
            await gate.releaseAll()
            for task in background {
                try await task.value
            }
            try await foreground.value
        }
    }
#endif
