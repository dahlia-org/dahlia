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
    case thumbnail
}

/// A content reference, not a credential. Clients must match its origin to a configured account.
public struct ScreenshotRemoteReference: Codable, Equatable, Sendable {
    public let origin: String
    public let vaultId: UUID
    public let meetingId: UUID
    public let screenshotId: UUID
    public let contentHash: String

    public init(origin: String, vaultId: UUID, meetingId: UUID, screenshotId: UUID, contentHash: String) {
        self.origin = origin
        self.vaultId = vaultId
        self.meetingId = meetingId
        self.screenshotId = screenshotId
        self.contentHash = contentHash
    }

    public func cacheKey(variant: ScreenshotVariant) -> String {
        let identity = "\(origin)|\(vaultId)|\(meetingId)|\(screenshotId)|\(contentHash)|v1|\(variant.rawValue)"
        return Self.digest(Data(identity.utf8))
    }

    public static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    public func jsonString() throws -> String {
        try String(decoding: JSONEncoder().encode(self), as: UTF8.self)
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
