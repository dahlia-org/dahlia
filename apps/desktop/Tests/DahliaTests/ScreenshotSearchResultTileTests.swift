import Testing
@testable import Dahlia

@Suite("Screenshot search result tile")
@MainActor
struct ScreenshotSearchResultTileTests {
    @Test("A left click on the hovered tile opens it when the popover dismisses")
    func opensHoveredTileAfterLeftClickDismissal() {
        #expect(ScreenshotSearchResultTile.shouldOpenAfterPopoverDismissal(
            isHovered: true,
            pressedMouseButtons: 1
        ))
        #expect(!ScreenshotSearchResultTile.shouldOpenAfterPopoverDismissal(
            isHovered: false,
            pressedMouseButtons: 1
        ))
        #expect(!ScreenshotSearchResultTile.shouldOpenAfterPopoverDismissal(
            isHovered: true,
            pressedMouseButtons: 0
        ))
    }
}
