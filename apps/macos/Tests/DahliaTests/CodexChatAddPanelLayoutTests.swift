#if canImport(Testing)
    import CoreGraphics
    import Testing
    @testable import Dahlia

    struct CodexChatAddPanelLayoutTests {
        @Test
        func opensBelowWhenThereIsRoomAndFlipsAtTheBottom() {
            let size = CGSize(width: 280, height: 114)
            #expect(CodexChatAddPanelLayout.offset(
                panelSize: size,
                windowBounds: CGRect(x: -20, y: -300, width: 720, height: 700)
            ).height == 38)
            #expect(CodexChatAddPanelLayout.offset(
                panelSize: size,
                windowBounds: CGRect(x: -20, y: -650, width: 720, height: 700)
            ).height == -122)
        }

        @Test(arguments: [CGFloat(320), 700])
        func connectorSubmenuFitsBesideTheOriginalMenu(windowWidth: CGFloat) {
            let bounds = CGRect(x: -6, y: -200, width: windowWidth, height: 360)
            let width = CodexChatAddPanelLayout.width(windowBounds: bounds, showsSubmenu: true)
            let size = CGSize(width: width * 2 + CodexChatAddPanelLayout.submenuSpacing, height: 180)
            let offset = CodexChatAddPanelLayout.offset(panelSize: size, windowBounds: bounds)
            #expect(width > 0)
            #expect(bounds.contains(CGRect(origin: CGPoint(x: offset.width, y: offset.height), size: size)))
        }

        @Test
        func keepsPanelWithinNarrowWindowsAndBoundsTallLists() {
            let bounds = CGRect(x: -280, y: -200, width: 320, height: 360)
            let size = CGSize(
                width: CodexChatAddPanelLayout.width(windowBounds: bounds),
                height: CodexChatAddPanelLayout.maximumHeight(windowBounds: bounds)
            )
            let offset = CodexChatAddPanelLayout.offset(panelSize: size, windowBounds: bounds)
            #expect(size.width == 280)
            #expect(size.height == 184)
            #expect(bounds.contains(CGRect(origin: CGPoint(x: offset.width, y: offset.height), size: size)))
        }
    }
#endif
