import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct CodexChatApprovalMethodPanelLayoutTests {
        @Test
        func usesPreferredWidthAndAdjustsOnlyAtTheWindowEdge() {
            let wideWindow = CGRect(x: -70, y: -500, width: 1_280, height: 800)
            let width = CodexChatApprovalMethodPanelLayout.width(windowBounds: wideWindow)

            #expect(width == CodexChatApprovalMethodPanelLayout.preferredWidth)
            #expect(CodexChatApprovalMethodPanelLayout.horizontalOffset(
                windowBounds: wideWindow,
                panelWidth: width
            ) == 0)
        }

        @Test
        func fitsInsideANarrowWindow() {
            let narrowWindow = CGRect(x: -70, y: -500, width: 420, height: 700)
            let width = CodexChatApprovalMethodPanelLayout.width(windowBounds: narrowWindow)

            #expect(width == 388)
            #expect(CodexChatApprovalMethodPanelLayout.horizontalOffset(
                windowBounds: narrowWindow,
                panelWidth: width
            ) == -54)
        }
    }
#endif
