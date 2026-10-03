@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CodexChatComposerFocusDismissalTests {
        @Test
        func outsideClickClearsComposerFocusUnlessTheAddPanelIsOpen() {
            #expect(CodexChatComposer.dismissesComposerFocus(showsAddPanel: false))
            #expect(!CodexChatComposer.dismissesComposerFocus(showsAddPanel: true))
        }
    }
#endif
