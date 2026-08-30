#if canImport(Testing)
    import CoreGraphics
    import Testing
    @testable import Dahlia

    @MainActor
    struct DahliaWindowHeaderHelpLayoutTests {
        @Test
        func placesHelpAboveOnlyWhenItFits() {
            #expect(DahliaWindowHeaderHelpLayout.verticalOffset(buttonMinY: 80, helpHeight: 32) == -34)
            #expect(DahliaWindowHeaderHelpLayout.verticalOffset(buttonMinY: 20, helpHeight: 32) == 34)
            #expect(DahliaWindowHeaderHelpLayout.verticalOffset(buttonMinY: 80, helpHeight: 32, buttonHeight: 30) == -35)
        }

        @Test
        func clampsHorizontalOffsetToWindowBounds() {
            func offset(buttonMidX: CGFloat, helpWidth: CGFloat, windowMinX: CGFloat = 0) -> CGFloat {
                DahliaWindowHeaderHelpLayout.horizontalOffset(
                    buttonMidX: buttonMidX,
                    helpWidth: helpWidth,
                    windowBounds: CGRect(x: windowMinX, y: 0, width: 400, height: 300)
                )
            }

            #expect(offset(buttonMidX: 200, helpWidth: 100) == 0)
            #expect(offset(buttonMidX: 20, helpWidth: 100) == 38)
            #expect(offset(buttonMidX: 380, helpWidth: 100) == -38)
            #expect(offset(buttonMidX: 380, helpWidth: 390) == -180)
            #expect(offset(buttonMidX: 26, helpWidth: 100, windowMinX: -348) == -32)
        }

        @Test
        func placesHelpRelativeToContainerAndConstrainsItToWindowBounds() {
            let windowBounds = CGRect(x: 0, y: 0, width: 400, height: 300)
            let helpSize = CGSize(width: 100, height: 32)

            let containerRelativeOrigin = DahliaWindowHeaderHelpLayout.origin(
                buttonFrame: CGRect(x: 100, y: 80, width: 28, height: 28),
                helpSize: helpSize,
                containerOrigin: CGPoint(x: 10, y: 20),
                windowBounds: windowBounds
            )
            let constrainedOrigin = DahliaWindowHeaderHelpLayout.origin(
                buttonFrame: CGRect(x: 366, y: 80, width: 28, height: 28),
                helpSize: helpSize,
                containerOrigin: .zero,
                windowBounds: windowBounds
            )

            #expect(containerRelativeOrigin == CGPoint(x: 54, y: 24))
            #expect(constrainedOrigin.x == 292)
        }
    }
#endif
