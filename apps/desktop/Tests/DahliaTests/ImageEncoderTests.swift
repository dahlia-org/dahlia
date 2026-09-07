import CoreGraphics
import DahliaRuntimeSupport
import Foundation

#if canImport(Testing)
    import Testing

    struct ImageEncoderTests {
        @Test(arguments: [(3400, 2200), (2200, 3400), (160, 80)])
        func aiInputPreservesAspectRatioWithoutEnlargement(size: (Int, Int)) throws {
            let context = try makeContext(width: size.0, height: size.1)
            let image = try #require(context.makeImage())
            let data = try #require(ImageEncoder.encode(image))
            let resized = try #require(ImageEncoder.resizedIfPossible(data, maxLongEdge: ImageEncoder.aiInputMaximumLongEdge))
            let decoded = try #require(CGImageDecoder.decode(resized))
            let scale = min(1, 1280.0 / Double(max(size.0, size.1)))
            #expect(abs(Double(decoded.width) - Double(size.0) * scale) <= 1)
            #expect(abs(Double(decoded.height) - Double(size.1) * scale) <= 1)
            #expect(max(decoded.width, decoded.height) <= 1280)
            #expect(ImageEncoder.mimeType(for: resized) == "image/webp")
        }

        @Test(arguments: [CGFloat(1), CGFloat(0.5)])
        func encodesLossyWebPWithColorAlphaAndOrientation(alpha: CGFloat) throws {
            let context = try makeContext(width: 128, height: 64)
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: alpha))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
            context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: alpha))
            context.fill(CGRect(x: 64, y: 0, width: 64, height: 32))
            context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: alpha))
            context.fill(CGRect(x: 0, y: 32, width: 64, height: 32))
            // The fourth quadrant remains transparent.
            let original = try #require(context.makeImage())
            let data = try #require(ImageEncoder.encode(original, quality: 0.75))
            #expect(ImageEncoder.mimeType(for: data) == "image/webp")
            #expect(data.starts(with: Data("RIFF".utf8)))
            _ = try #require(data.range(of: Data("VP8 ".utf8)))
            #expect(ImageEncoder.fileExtension(mimeType: "image/webp", data: data) == "webp")
            let decoded = try #require(CGImageDecoder.decode(data))
            #expect(decoded.width == original.width)
            #expect(decoded.height == original.height)
            let rendered = try makeContext(width: decoded.width, height: decoded.height)
            rendered.draw(decoded, in: CGRect(x: 0, y: 0, width: decoded.width, height: decoded.height))
            let expected = try #require(context.data).assumingMemoryBound(to: UInt8.self)
            let actual = try #require(rendered.data).assumingMemoryBound(to: UInt8.self)
            for (x, y) in [(16, 16), (96, 16), (16, 48), (96, 48)] {
                let offset = y * context.bytesPerRow + x * 4
                for channel in 0 ..< 3 {
                    #expect(abs(Int(expected[offset + channel]) - Int(actual[offset + channel])) <= 12)
                }
                #expect(abs(Int(expected[offset + 3]) - Int(actual[offset + 3])) <= 1)
            }
        }

        @Test
        func imageBeyondWebPDimensionLimitFallsBackToJPEG() throws {
            let context = try makeContext(width: 16384, height: 1)
            let image = try #require(context.makeImage())
            let data = try #require(ImageEncoder.encode(image, quality: 0.75))
            #expect(ImageEncoder.mimeType(for: data) == "image/jpeg")
            #expect(ImageEncoder.fileExtension(mimeType: "image/jpeg", data: data) == "jpeg")
            let decoded = try #require(CGImageDecoder.decode(data))
            #expect(decoded.width == 16384)
            #expect(decoded.height == 1)
        }

        @Test
        func resizingLegacyJPEGProducesWebP() throws {
            let context = try makeContext(width: 16384, height: 1)
            let image = try #require(context.makeImage())
            let jpeg = try #require(ImageEncoder.encode(image, quality: 0.75))
            let resized = try #require(ImageEncoder.resizedIfPossible(jpeg, maxLongEdge: 1024))
            #expect(ImageEncoder.mimeType(for: resized) == "image/webp")
            let decoded = try #require(CGImageDecoder.decode(resized))
            #expect(decoded.width == 1024)
            #expect(decoded.height == 1)
        }

        @Test
        func invalidInputsAreRejected() throws {
            let context = try makeContext(width: 1, height: 1)
            let image = try #require(context.makeImage())
            for quality in [CGFloat.nan, .infinity, -0.1, 1.1] {
                #expect(ImageEncoder.encode(image, quality: quality) == nil)
            }
            #expect(ImageEncoder.resizedIfPossible(Data("invalid".utf8), maxLongEdge: 1024) == nil)
        }

        private func makeContext(width: Int, height: Int) throws -> CGContext {
            let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            return try #require(CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ))
        }
    }
#endif
