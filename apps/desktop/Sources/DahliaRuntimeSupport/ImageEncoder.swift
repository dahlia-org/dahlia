import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import libwebp
import UniformTypeIdentifiers

package enum ImageEncoder {
    package static let preferredFileExtension = "webp"
    package static let defaultQuality: CGFloat = 0.75

    package static func mimeType(for data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let typeIdentifier = CGImageSourceGetType(source) as String? else {
            return nil
        }

        return switch typeIdentifier {
        case UTType.webP.identifier: "image/webp"
        case UTType.jpeg.identifier: "image/jpeg"
        case UTType.png.identifier: "image/png"
        case UTType.gif.identifier: "image/gif"
        case UTType.tiff.identifier: "image/tiff"
        default: nil
        }
    }

    package static func fileExtension(for mimeType: String) -> String? {
        switch mimeType.lowercased() {
        case "image/webp": "webp"
        case "image/jpeg": "jpeg"
        case "image/png": "png"
        case "image/gif": "gif"
        case "image/tiff": "tiff"
        default: nil
        }
    }

    package static func fileExtension(mimeType: String, data: Data) -> String {
        fileExtension(for: mimeType)
            ?? fileExtension(for: self.mimeType(for: data) ?? "")
            ?? preferredFileExtension
    }

    package static func encode(_ cgImage: CGImage, quality: CGFloat = Self.defaultQuality) -> Data? {
        guard quality.isFinite, (0 ... 1).contains(quality) else { return nil }
        if let data = encodeWebP(cgImage, quality: quality) {
            return data
        }
        return encode(cgImage, quality: quality, typeIdentifier: UTType.jpeg.identifier)
    }

    private static func encodeWebP(_ image: CGImage, quality: CGFloat) -> Data? {
        // ImageIO decodes WebP but cannot encode it. libwebp expects straight RGBA.
        guard image.width <= WEBP_MAX_DIMENSION, image.height <= WEBP_MAX_DIMENSION,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: image.width,
                  height: image.height,
                  bitsPerComponent: 8,
                  bytesPerRow: image.width * 4,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
              ), let pixels = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        var buffer = vImage_Buffer(
            data: pixels,
            height: vImagePixelCount(image.height),
            width: vImagePixelCount(image.width),
            rowBytes: context.bytesPerRow
        )
        var destination = buffer
        guard vImageUnpremultiplyData_RGBA8888(&buffer, &destination, vImage_Flags(kvImageDoNotTile)) == kvImageNoError else {
            return nil
        }
        var output: UnsafeMutablePointer<UInt8>?
        // The simple API uses lossy compression, the default preset, and method 4.
        let count = withExtendedLifetime(context) {
            WebPEncodeRGBA(
                pixels.assumingMemoryBound(to: UInt8.self),
                Int32(image.width), Int32(image.height), Int32(context.bytesPerRow),
                Float(quality * 100), &output
            )
        }
        defer { WebPFree(output) }
        guard count > 0, let output else { return nil }
        return Data(bytes: output, count: count)
    }

    private static func encode(_ cgImage: CGImage, quality: CGFloat, typeIdentifier: String) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, typeIdentifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, [
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    package static func resizedIfPossible(_ data: Data, maxLongEdge: Int, quality: CGFloat = Self.defaultQuality) -> Data? {
        guard let thumbnail = CGImageDecoder.decode(data, maxPixelSize: maxLongEdge) else { return nil }
        return encode(thumbnail, quality: quality)
    }

    package static func resized(_ data: Data, maxLongEdge: Int, quality: CGFloat = Self.defaultQuality) -> Data {
        resizedIfPossible(data, maxLongEdge: maxLongEdge, quality: quality) ?? data
    }
}
