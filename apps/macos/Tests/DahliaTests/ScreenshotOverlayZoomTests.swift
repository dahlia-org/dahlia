#if canImport(Testing)
    import Testing
    @testable import Dahlia

    struct ScreenshotOverlayZoomTests {
        @Test
        func staysWithinHalfAndDoubleSize() {
            #expect(ScreenshotOverlayZoom.clamped(0.25) == 0.5)
            #expect(ScreenshotOverlayZoom.clamped(1.25) == 1.25)
            #expect(ScreenshotOverlayZoom.clamped(2.25) == 2)
        }
    }
#endif
