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
    }

    @Test
    func keepsHelpCenteredWhenItFits() {
        let offset = DahliaWindowHeaderHelpLayout.horizontalOffset(
            buttonMidX: 200,
            helpWidth: 100,
            windowBounds: CGRect(x: 0, y: 0, width: 400, height: 300)
        )

        #expect(offset == 0)
    }

    @Test
    func placesHelpRelativeToContainer() {
        let origin = DahliaWindowHeaderHelpLayout.origin(
            buttonFrame: CGRect(x: 100, y: 80, width: 28, height: 28),
            helpSize: CGSize(width: 100, height: 32),
            containerOrigin: CGPoint(x: 10, y: 20),
            windowBounds: CGRect(x: 0, y: 0, width: 400, height: 300)
        )

        #expect(origin == CGPoint(x: 54, y: 24))
    }

    @Test
    func shiftsHelpRightAtLeadingEdge() {
        let offset = DahliaWindowHeaderHelpLayout.horizontalOffset(
            buttonMidX: 20,
            helpWidth: 100,
            windowBounds: CGRect(x: 0, y: 0, width: 400, height: 300)
        )

        #expect(offset == 38)
    }

    @Test
    func shiftsHelpLeftAtTrailingEdge() {
        let offset = DahliaWindowHeaderHelpLayout.horizontalOffset(
            buttonMidX: 380,
            helpWidth: 100,
            windowBounds: CGRect(x: 0, y: 0, width: 400, height: 300)
        )

        #expect(offset == -38)
    }

    @Test
    func centersHelpInContainerWhenItIsWiderThanAvailableSpace() {
        let offset = DahliaWindowHeaderHelpLayout.horizontalOffset(
            buttonMidX: 380,
            helpWidth: 390,
            windowBounds: CGRect(x: 0, y: 0, width: 400, height: 300)
        )

        #expect(offset == -180)
    }

    @Test
    func constrainsHelpToWindowBoundsBeyondItsHeader() {
        let offset = DahliaWindowHeaderHelpLayout.horizontalOffset(
            buttonMidX: 26,
            helpWidth: 100,
            windowBounds: CGRect(x: -348, y: 0, width: 400, height: 300)
        )

        #expect(offset == -32)
    }

    @Test
    func constrainsContainerOverlayHelpToWindowBounds() {
        let origin = DahliaWindowHeaderHelpLayout.origin(
            buttonFrame: CGRect(x: 366, y: 80, width: 28, height: 28),
            helpSize: CGSize(width: 100, height: 32),
            containerOrigin: .zero,
            windowBounds: CGRect(x: 0, y: 0, width: 400, height: 300)
        )

        #expect(origin.x == 292)
    }
}
#endif
