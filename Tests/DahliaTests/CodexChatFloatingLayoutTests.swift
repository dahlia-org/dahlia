import CoreGraphics
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct CodexChatFloatingLayoutTests {
        @Test
        func snapsToNearestBottomCorner() {
            var layout = CodexChatFloatingLayout(dockSide: .right)

            layout.snap(horizontalCenter: 200, availableWidth: 1000)
            #expect(layout.dockSide == .left)

            layout.snap(horizontalCenter: 800, availableWidth: 1000)
            #expect(layout.dockSide == .right)
        }

        @Test
        func resizeClampsToMinimumAndAvailableBounds() {
            var layout = CodexChatFloatingLayout(dockSide: .right)
            let available = CGSize(width: 900, height: 700)

            layout.resize(translation: CGSize(width: 1000, height: 1000), availableSize: available)
            #expect(layout.size == CodexChatFloatingLayout.minimumSize)

            layout.resize(translation: CGSize(width: -2000, height: -2000), availableSize: available)
            #expect(layout.size == CGSize(width: 868, height: 668))
        }

        @Test
        func originStaysInsideAvailableBounds() {
            let available = CGSize(width: 1000, height: 800)
            let layout = CodexChatFloatingLayout(dockSide: .right)
            let origin = layout.origin(
                in: available,
                dragTranslation: CGSize(width: 10000, height: -10000)
            )

            #expect(origin.x == 464)
            #expect(origin.y == 224)
        }
    }
#endif
