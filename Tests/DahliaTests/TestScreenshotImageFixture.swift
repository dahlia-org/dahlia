#if canImport(Testing)
    import AppKit
    import Foundation

    enum TestScreenshotImageFixture {
        @MainActor
        static func data(using fileType: NSBitmapImageRep.FileType) -> Data? {
            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 1,
                pixelsHigh: 1,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ), let pixels = bitmap.bitmapData else { return nil }

            pixels[0] = 255
            pixels[1] = 0
            pixels[2] = 0
            pixels[3] = 255
            return bitmap.representation(using: fileType, properties: [:])
        }
    }
#endif
