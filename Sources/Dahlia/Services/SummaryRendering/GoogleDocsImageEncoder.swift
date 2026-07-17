import Foundation
import ImageIO
import UniformTypeIdentifiers

enum GoogleDocsImageEncoder {
    struct EncodedImage {
        let data: Data
        let pixelWidth: Int
        let pixelHeight: Int
    }

    private static let maxLongEdge = 1600

    static func encode(_ data: Data) -> EncodedImage? {
        guard let image = CGImageDecoder.decode(data, maxPixelSize: maxLongEdge) else { return nil }

        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.78,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }

        return EncodedImage(
            data: encoded as Data,
            pixelWidth: image.width,
            pixelHeight: image.height
        )
    }
}
