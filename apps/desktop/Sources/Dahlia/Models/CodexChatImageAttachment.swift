import DahliaRuntimeSupport
import Foundation

struct CodexChatImageAttachment: Identifiable, Equatable, Sendable {
    static let maximumAttachmentCount = 10
    static let maximumInputByteCount = 25 * 1024 * 1024

    let id: UUID
    let data: Data
    let mimeType: String

    var dataURI: String {
        "data:\(mimeType);base64,\(data.base64EncodedString())"
    }

    init(id: UUID = UUID.v7(), data: Data, mimeType: String) {
        self.id = id
        self.data = data
        self.mimeType = mimeType
    }

    init?(id: UUID = UUID.v7(), dataURI: String) {
        guard dataURI.utf8.count <= Self.maximumInputByteCount * 4 / 3 + 128,
              dataURI.hasPrefix("data:image/"),
              let separator = dataURI.range(of: ";base64,"),
              separator.lowerBound > dataURI.startIndex,
              dataURI.distance(from: separator.upperBound, to: dataURI.endIndex)
              <= Self.maximumInputByteCount * 4 / 3 + 4,
              let data = Data(base64Encoded: String(dataURI[separator.upperBound...])),
              !data.isEmpty,
              data.count <= Self.maximumInputByteCount,
              let detectedMIMEType = ImageEncoder.mimeType(for: data) else { return nil }
        self.id = id
        self.data = data
        mimeType = detectedMIMEType
    }
}
