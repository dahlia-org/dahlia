import CoreGraphics
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CodexChatFloatingLayoutModelTests {
        private let available = CGSize(width: 1000, height: 800)

        @Test
        func draggingMovesTheOriginWithoutChangingTheLayout() {
            let model = CodexChatFloatingLayoutModel(dockSide: .right)
            let resting = model.layout

            model.updateDragging(CGSize(width: -300, height: 0))

            #expect(model.dragTranslation == CGSize(width: -300, height: 0))
            #expect(model.layout == resting)
            #expect(
                model.layout.origin(in: available, dragTranslation: model.dragTranslation).x
                    < resting.origin(in: available).x
            )
        }

        @Test
        func finishingADragDocksToTheNearestSideAndClearsTheTranslation() {
            let model = CodexChatFloatingLayoutModel(dockSide: .right)
            model.updateDragging(CGSize(width: -600, height: 0))

            model.finishDragging(CGSize(width: -600, height: 0), availableSize: available, animated: false)

            #expect(model.layout.dockSide == .left)
            #expect(model.dragTranslation == .zero)
        }

        @Test
        func finishingAShortDragKeepsTheCurrentSide() {
            let model = CodexChatFloatingLayoutModel(dockSide: .right)
            model.updateDragging(CGSize(width: -20, height: 0))

            model.finishDragging(CGSize(width: -20, height: 0), availableSize: available, animated: false)

            #expect(model.layout.dockSide == .right)
            #expect(model.dragTranslation == .zero)
        }

        @Test
        func resizeAppliesEachTranslationToTheDragStartLayout() {
            let model = CodexChatFloatingLayoutModel(dockSide: .right)
            let start = model.layout
            var expected = start
            expected.resize(
                from: .topLeft,
                translation: CGSize(width: -80, height: -60),
                availableSize: available
            )

            // ドラッグ中の中間イベントは開始時のレイアウトを基準に適用し、積み上げない。
            model.resize(
                from: .topLeft,
                start: start,
                translation: CGSize(width: -40, height: -30),
                availableSize: available
            )
            model.resize(
                from: .topLeft,
                start: start,
                translation: CGSize(width: -80, height: -60),
                availableSize: available
            )

            #expect(model.layout == expected)
        }

        @Test
        func clampFitsTheLayoutIntoASmallerContainer() {
            let model = CodexChatFloatingLayoutModel(dockSide: .right)
            let smaller = CGSize(width: 420, height: 400)
            var expected = model.layout
            expected.clamp(to: smaller)

            model.clamp(to: smaller)

            #expect(model.layout == expected)
            #expect(model.layout.size.width <= smaller.width)
            #expect(model.layout.size.height <= smaller.height)
        }
    }
#endif
