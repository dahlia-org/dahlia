@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CodexChatComposerFocusDismissalTests {
        @Test
        func outsideClickClearsComposerFocus() {
            #expect(CodexChatComposer.dismissesComposerFocus(showsAddPanel: false))
        }

        @Test
        func addPanelKeepsComposerFocusWhileSelectingASuggestion() {
            #expect(!CodexChatComposer.dismissesComposerFocus(showsAddPanel: true))
        }
    }
#endif
