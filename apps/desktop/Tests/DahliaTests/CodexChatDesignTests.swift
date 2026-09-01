#if canImport(Testing)
import Testing
@testable import Dahlia

struct CodexChatDesignTests {
    @Test
    func configurationPanelHeightTracksEffortCount() {
        #expect(CodexChatDesign.configurationPanelHeight(effortCount: 4) == 206)
        #expect(CodexChatDesign.configurationPanelHeight(effortCount: 5) == 238)
        #expect(CodexChatDesign.configurationPanelHeight(effortCount: 8) == 278)
    }
}
#endif
