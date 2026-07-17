import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

package enum ImageEncoder {
    package static let supportsWebP: Bool = {
        let types = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return types.contains(UTType.webP.identifier)
    }()

    package static var preferredFileExtension: String {
        supportsWebP ? "webp" : "jpeg"
    }

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

    package static func encode(_ cgImage: CGImage, quality: CGFloat) -> Data? {
        if supportsWebP, let data = encode(cgImage, quality: quality, typeIdentifier: UTType.webP.identifier) {
            return data
        }
        return encode(cgImage, quality: quality, typeIdentifier: UTType.jpeg.identifier)
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

    package static func resizedIfPossible(_ data: Data, maxLongEdge: Int, quality: CGFloat = 0.70) -> Data? {
        guard let thumbnail = CGImageDecoder.decode(data, maxPixelSize: maxLongEdge) else { return nil }
        return encode(thumbnail, quality: quality)
    }

    package static func resized(_ data: Data, maxLongEdge: Int, quality: CGFloat = 0.70) -> Data {
        resizedIfPossible(data, maxLongEdge: maxLongEdge, quality: quality) ?? data
    }
}
