import CoreGraphics
import DahliaRuntimeSupport
import Foundation
import ImageIO
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct CodexChatImageProcessorTests {
        @Test
        func imageIsResizedToMaximumLongEdge() async throws {
            let context = try #require(CGContext(
                data: nil,
                width: 2048,
                height: 1024,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            let sourceImage = try #require(context.makeImage())
            let sourceData = try #require(ImageEncoder.encode(sourceImage, quality: 0.9))

            let attachment = try #require(await CodexChatImageProcessor.shared.process(sourceData))
            let imageSource = try #require(CGImageSourceCreateWithData(attachment.data as CFData, nil))
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any])
            let width = try #require(properties[kCGImagePropertyPixelWidth] as? Int)
            let height = try #require(properties[kCGImagePropertyPixelHeight] as? Int)

            #expect(max(width, height) == 1024)
            #expect(attachment.mimeType.hasPrefix("image/"))
        }

        @Test
        func invalidImageIsRejected() async {
            let attachment = await CodexChatImageProcessor.shared.process(Data("not an image".utf8))
            #expect(attachment == nil)
        }

        @Test
        func oversizedInputIsRejectedBeforeDecoding() async {
            let data = Data(count: CodexChatImageAttachment.maximumInputByteCount + 1)
            let attachment = await CodexChatImageProcessor.shared.process(data)
            #expect(attachment == nil)
        }

        @Test
        func corruptHistoryDataURIIsRejected() {
            #expect(CodexChatImageAttachment(dataURI: "data:image/jpeg;base64,AA==") == nil)
        }
    }
#endif
