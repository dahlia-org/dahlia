import CryptoKit
import Foundation

public enum ScreenshotContentError: Error, Sendable {
    case unavailable
    case authorizationRequired
    case deleted
    case integrityFailure
}

public enum ScreenshotVariant: String, Codable, Sendable {
    case original
    case thumbnail = "thumb_360"
}

/// A content reference, not a credential. Clients must match its origin to a configured account.
public struct ScreenshotRemoteReference: Codable, Equatable, Sendable {
    public let origin: String
    public let accountConnectionId: UUID?
    public let fileId: UUID
    public let contentHash: String

    public init(origin: String, accountConnectionId: UUID?, fileId: UUID, contentHash: String) {
        self.origin = origin
        self.accountConnectionId = accountConnectionId
        self.fileId = fileId
        self.contentHash = contentHash
    }

    public func cacheKey(variant: ScreenshotVariant) -> String {
        let scope = accountConnectionId.map { "server/\($0.uuidString.lowercased())" } ?? "local"
        let representation = variant == .original ? "original" : "variants/v1/\(variant.rawValue).webp"
        return "\(scope)/files/\(fileId.uuidString.lowercased())/\(representation)"
    }

    public static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    public func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try String(decoding: encoder.encode(self), as: UTF8.self)
    }
}

public struct ScreenshotContent: Sendable {
    public let data: Data
    public let mimeType: String
    public let variant: ScreenshotVariant

    public init(data: Data, mimeType: String, variant: ScreenshotVariant) {
        self.data = data
        self.mimeType = mimeType
        self.variant = variant
    }
}
