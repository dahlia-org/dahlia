import Foundation
@testable import Dahlia

#if canImport(Testing)
import Testing

struct SpeechTranscriberServiceTests {
    @Test
    func normalizedTranscriptTextRejectsSingleA() {
        let text = SpeechTranscriberService.normalizedTranscriptText("あ")

        #expect(text == nil)
    }

    @Test
    func normalizedTranscriptTextRejectsSinglePeriod() {
        let text = SpeechTranscriberService.normalizedTranscriptText(".")

        #expect(text == nil)
    }

    @Test
    func normalizedTranscriptTextTrimsWhitespaceBeforeFiltering() {
        let text = SpeechTranscriberService.normalizedTranscriptText("  あ \n")

        #expect(text == nil)
    }

    @Test
    func normalizedTranscriptTextPreservesOtherContent() {
        let text = SpeechTranscriberService.normalizedTranscriptText("はい")

        #expect(text == "はい")
    }
}
#endif
