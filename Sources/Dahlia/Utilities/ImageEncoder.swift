import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 画像エンコードのユーティリティ。WebP 優先、非対応環境では JPEG にフォールバック。
enum ImageEncoder {
    static let supportsWebP: Bool = {
        let types = CGImageDestinationCopyTypeIdentifiers() as! [String]
        return types.contains(UTType.webP.identifier)
    }()

    static var preferredMIMEType: String {
        supportsWebP ? "image/webp" : "image/jpeg"
    }

    static var preferredFileExtension: String {
        supportsWebP ? "webp" : "jpeg"
    }

    static func mimeType(for data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let typeIdentifier = CGImageSourceGetType(source) as String? else {
            return nil
        }

        switch typeIdentifier {
        case UTType.webP.identifier:
            return "image/webp"
        case UTType.jpeg.identifier:
            return "image/jpeg"
        case UTType.png.identifier:
            return "image/png"
        case UTType.gif.identifier:
            return "image/gif"
        case UTType.tiff.identifier:
            return "image/tiff"
        default:
            return nil
        }
    }

    static func fileExtension(for mimeType: String) -> String? {
        switch mimeType.lowercased() {
        case "image/webp":
            "webp"
        case "image/jpeg":
            "jpeg"
        case "image/png":
            "png"
        case "image/gif":
            "gif"
        case "image/tiff":
            "tiff"
        default:
            nil
        }
    }

    /// CGImage をエンコードする。WebP 優先、非対応時は JPEG フォールバック。
    static func encode(_ cgImage: CGImage, quality: CGFloat) -> Data? {
        let outputType = supportsWebP ? UTType.webP.identifier : UTType.jpeg.identifier
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, outputType as CFString, 1, nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, [
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return data as Data
    }

    /// 画像データを長辺 maxLongEdge 以下にリサイズして再エンコードする。
    /// リサイズ不要またはエラー時は再エンコードのみ行い形式を統一する。
    static func resized(_ data: Data, maxLongEdge: Int, quality: CGFloat = 0.70) -> Data {
        guard let thumbnail = CGImageDecoder.decode(data, maxPixelSize: maxLongEdge) else {
            return data
        }

        return encode(thumbnail, quality: quality) ?? data
    }
}
