@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct OrganizationCanvasZoomTests {
        @Test
        func clampsToolbarAndGestureZoomToSupportedRange() {
            #expect(OrganizationCanvasZoom.clamped(0.25) == OrganizationCanvasZoom.minimum)
            #expect(OrganizationCanvasZoom.clamped(2.5) == OrganizationCanvasZoom.maximum)
            #expect(OrganizationCanvasZoom.applying(magnification: 1.25, to: 1.2) == 1.5)
            #expect(
                OrganizationCanvasZoom.applying(magnification: 0.1, to: 1)
                    == OrganizationCanvasZoom.minimum
            )
            #expect(
                OrganizationCanvasZoom.applying(magnification: 10, to: 1)
                    == OrganizationCanvasZoom.maximum
            )
        }
    }
#endif
