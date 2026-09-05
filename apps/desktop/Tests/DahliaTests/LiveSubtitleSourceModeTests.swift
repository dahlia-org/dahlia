@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct LiveSubtitleSourceModeTests {
        @Test
        func defaultsToSystemAudioOnly() {
            #expect(LiveSubtitleSourceMode.defaultMode == .systemAudioOnly)
            #expect(!LiveSubtitleSourceMode.defaultMode.includesAudioSource("mic"))
            #expect(LiveSubtitleSourceMode.defaultMode.includesAudioSource("system"))
        }

        @Test
        func resolvesStoredRawValuesWithoutChangingTheirFormat() {
            #expect(LiveSubtitleSourceMode(storedRawValue: "includeMicrophone") == .includeMicrophone)
            #expect(LiveSubtitleSourceMode(storedRawValue: "systemAudioOnly") == .systemAudioOnly)
            #expect(LiveSubtitleSourceMode(storedRawValue: "unsupported") == .defaultMode)
        }

        @Test
        func mapsMicrophoneToggleToSourceMode() {
            #expect(LiveSubtitleSourceMode(includesMicrophone: true) == .includeMicrophone)
            #expect(LiveSubtitleSourceMode(includesMicrophone: false) == .systemAudioOnly)
            #expect(LiveSubtitleSourceMode.includeMicrophone.includesMicrophone)
            #expect(!LiveSubtitleSourceMode.systemAudioOnly.includesMicrophone)
        }
    }
#endif
