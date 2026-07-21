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

            layout.resize(
                from: .topLeft,
                translation: CGSize(width: 1000, height: 1000),
                availableSize: available
            )
            #expect(layout.size == CodexChatFloatingLayout.minimumSize)

            layout.resize(
                from: .topLeft,
                translation: CGSize(width: -2000, height: -2000),
                availableSize: available
            )
            #expect(layout.size == CGSize(width: 868, height: 668))
        }

        @Test
        func topResizeMovesOnlyTopEdge() {
            var layout = CodexChatFloatingLayout(dockSide: .right)
            let available = CGSize(width: 1000, height: 800)
            let initialFrame = layout.frame(in: available)

            layout.resize(from: .top, translation: CGSize(width: 200, height: 100), availableSize: available)
            let resizedFrame = layout.frame(in: available)

            #expect(resizedFrame.minX == initialFrame.minX)
            #expect(resizedFrame.maxX == initialFrame.maxX)
            #expect(resizedFrame.minY == initialFrame.minY + 100)
            #expect(resizedFrame.maxY == initialFrame.maxY)
        }

        @Test
        func topResizePreservesRightDockAcrossAvailableWidthChanges() {
            var layout = CodexChatFloatingLayout(dockSide: .right)

            layout.resize(
                from: .top,
                translation: CGSize(width: 0, height: 100),
                availableSize: CGSize(width: 1000, height: 800)
            )

            let widerAvailableSize = CGSize(width: 1200, height: 800)
            #expect(layout.origin(in: widerAvailableSize).x == 664)
        }

        @Test
        func leftResizeMovesOnlyLeftEdge() {
            var layout = CodexChatFloatingLayout(dockSide: .right)
            let available = CGSize(width: 1000, height: 800)
            let initialFrame = layout.frame(in: available)

            layout.resize(from: .left, translation: CGSize(width: 100, height: 200), availableSize: available)
            let resizedFrame = layout.frame(in: available)

            #expect(resizedFrame.minX == initialFrame.minX + 100)
            #expect(resizedFrame.maxX == initialFrame.maxX)
            #expect(resizedFrame.minY == initialFrame.minY)
            #expect(resizedFrame.maxY == initialFrame.maxY)
        }

        @Test
        func rightResizeMovesOnlyRightEdge() {
            var layout = CodexChatFloatingLayout(dockSide: .left)
            let available = CGSize(width: 1000, height: 800)
            let initialFrame = layout.frame(in: available)

            layout.resize(from: .right, translation: CGSize(width: 100, height: 200), availableSize: available)
            let resizedFrame = layout.frame(in: available)

            #expect(resizedFrame.minX == initialFrame.minX)
            #expect(resizedFrame.maxX == initialFrame.maxX + 100)
            #expect(resizedFrame.minY == initialFrame.minY)
            #expect(resizedFrame.maxY == initialFrame.maxY)
        }

        @Test
        func innerEdgeResizePreservesDockAcrossAvailableWidthChanges() {
            var rightDockedLayout = CodexChatFloatingLayout(dockSide: .right)
            var leftDockedLayout = CodexChatFloatingLayout(dockSide: .left)
            let initialAvailableSize = CGSize(width: 1000, height: 800)

            rightDockedLayout.resize(
                from: .left,
                translation: CGSize(width: 100, height: 0),
                availableSize: initialAvailableSize
            )
            leftDockedLayout.resize(
                from: .right,
                translation: CGSize(width: 100, height: 0),
                availableSize: initialAvailableSize
            )

            let widerAvailableSize = CGSize(width: 1200, height: 800)
            #expect(rightDockedLayout.origin(in: widerAvailableSize).x == 764)
            #expect(leftDockedLayout.origin(in: widerAvailableSize).x == CodexChatFloatingLayout.margin)
        }

        @Test
        func cornerResizeMovesBothRequestedEdges() {
            var topLeftLayout = CodexChatFloatingLayout(dockSide: .right)
            var topRightLayout = CodexChatFloatingLayout(dockSide: .left)
            let available = CGSize(width: 1000, height: 800)
            let topLeftInitialFrame = topLeftLayout.frame(in: available)
            let topRightInitialFrame = topRightLayout.frame(in: available)

            topLeftLayout.resize(
                from: .topLeft,
                translation: CGSize(width: 100, height: 100),
                availableSize: available
            )
            topRightLayout.resize(
                from: .topRight,
                translation: CGSize(width: 100, height: 100),
                availableSize: available
            )
            let topLeftFrame = topLeftLayout.frame(in: available)
            let topRightFrame = topRightLayout.frame(in: available)

            #expect(topLeftFrame.minX == topLeftInitialFrame.minX + 100)
            #expect(topLeftFrame.maxX == topLeftInitialFrame.maxX)
            #expect(topLeftFrame.minY == topLeftInitialFrame.minY + 100)
            #expect(topLeftFrame.maxY == topLeftInitialFrame.maxY)
            #expect(topRightFrame.minX == topRightInitialFrame.minX)
            #expect(topRightFrame.maxX == topRightInitialFrame.maxX + 100)
            #expect(topRightFrame.minY == topRightInitialFrame.minY + 100)
            #expect(topRightFrame.maxY == topRightInitialFrame.maxY)
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

        @Test
        func snappingAfterOuterEdgeResizeRestoresDockedOrigin() {
            let available = CGSize(width: 1000, height: 800)
            var layout = CodexChatFloatingLayout(dockSide: .right)

            layout.resize(from: .right, translation: CGSize(width: -100, height: 0), availableSize: available)
            #expect(layout.origin(in: available).x == 464)
            #expect(layout.origin(in: CGSize(width: 1200, height: 800)).x == 464)

            layout.snap(horizontalCenter: 200, availableWidth: available.width)
            #expect(layout.dockSide == .left)
            #expect(layout.origin(in: available).x == CodexChatFloatingLayout.margin)
        }

        @Test
        func resizeHandlesDoNotOverlapMinimizeButton() {
            let size = CodexChatFloatingLayout.defaultSize
            let buttonSize = CodexChatDesign.headerControlSize
            let contentFrame = CodexChatResizeHandles.contentFrame(for: size)
            let minimizeButtonFrame = CGRect(
                x: contentFrame.maxX - CodexChatDesign.headerHorizontalPadding - buttonSize,
                y: contentFrame.minY + (CodexChatDesign.headerHeight - buttonSize) / 2,
                width: buttonSize,
                height: buttonSize
            )

            for edge in CodexChatResizeEdge.allCases {
                let resizeFrame = CodexChatResizeHandles.frame(for: edge, in: size)
                #expect(!resizeFrame.intersects(minimizeButtonFrame))
            }
        }

        @Test
        func straightResizeHandlesStayOutsideChatContent() {
            let size = CodexChatFloatingLayout.defaultSize
            let contentFrame = CodexChatResizeHandles.contentFrame(for: size)

            for edge in [CodexChatResizeEdge.top, .left, .right] {
                let resizeFrame = CodexChatResizeHandles.frame(for: edge, in: size)
                #expect(!resizeFrame.intersects(contentFrame))
            }
        }
    }
#endif
