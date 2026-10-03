#if canImport(Testing)
    import Testing
    @testable import Dahlia

    @MainActor
    struct RecordingAudioLevelStoreTests {
        @Test
        func clampsLevelsAndRemovesInactiveSources() {
            let store = RecordingAudioLevelStore()
            store.update(source: .microphone, level: 2)
            store.update(source: .system, level: -1)

            #expect(store.level(for: .microphone) == 1)
            #expect(store.level(for: .system) == 0)

            store.retain(sources: [.system])

            #expect(store.level(for: .microphone) == 0)
            #expect(store.level(for: .system) == 0)
        }

        @Test
        func resetClearsEverySource() {
            let store = RecordingAudioLevelStore()
            store.update(source: .microphone, level: 0.5)
            store.update(source: .system, level: 0.25)

            store.reset(source: .microphone)

            #expect(store.level(for: .microphone) == 0)
            #expect(store.level(for: .system) == 0.25)
            store.reset()

            #expect(store.level(for: .microphone) == 0)
            #expect(store.level(for: .system) == 0)
        }
    }
#endif
