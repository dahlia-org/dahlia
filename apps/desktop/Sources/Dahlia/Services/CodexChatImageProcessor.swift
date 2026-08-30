import DahliaRuntimeSupport
import Foundation

actor CodexChatImageProcessor {
    static let shared = CodexChatImageProcessor()

    private static let maximumLongEdge = 1024

    func process(_ data: Data) -> CodexChatImageAttachment? {
        guard data.count <= CodexChatImageAttachment.maximumInputByteCount,
              let resized = ImageEncoder.resizedIfPossible(
                  data,
                  maxLongEdge: Self.maximumLongEdge
              ), let mimeType = ImageEncoder.mimeType(for: resized) else { return nil }
        return CodexChatImageAttachment(data: resized, mimeType: mimeType)
    }

    func process(_ dataItems: [Data]) -> [CodexChatImageAttachment?] {
        dataItems.map { process($0) }
    }

    func process(_ url: URL) -> CodexChatImageAttachment? {
        if let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           fileSize > CodexChatImageAttachment.maximumInputByteCount {
            return nil
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return process(data)
    }

    func process(_ urls: [URL]) -> [CodexChatImageAttachment?] {
        urls.map { process($0) }
    }
}
