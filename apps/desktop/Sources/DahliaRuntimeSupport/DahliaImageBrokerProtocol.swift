import Darwin
import Foundation

/// Image-only IPC: helpers receive bytes and never receive account credentials.
public enum DahliaImageBrokerProtocol {
    public struct Request: Codable, Sendable {
        public let vaultId: UUID
        public let meetingId: UUID
        public let screenshotId: UUID

        public init(vaultId: UUID, meetingId: UUID, screenshotId: UUID) {
            self.vaultId = vaultId
            self.meetingId = meetingId
            self.screenshotId = screenshotId
        }
    }

    public struct Response: Codable, Sendable {
        public let byteCount: Int
        public let error: String?

        public init(byteCount: Int, error: String? = nil) {
            self.byteCount = byteCount
            self.error = error
        }
    }

    public static func socketURL(
        profile: DahliaRuntimeProfile = DahliaApplicationSupport.profile(),
        applicationSupportDirectory: URL = .applicationSupportDirectory
    ) -> URL {
        DahliaTokenBrokerProtocol.socketURL(profile: profile, applicationSupportDirectory: applicationSupportDirectory)
            .deletingLastPathComponent().appending(path: "images.sock")
    }

    public static func requestImage(_ request: Request, socketURL: URL = socketURL()) throws -> Data {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(descriptor) }
        try configure(descriptor, timeout: 35)
        var address = try DahliaTokenBrokerProtocol.unixAddress(path: socketURL.path)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, DahliaTokenBrokerProtocol.unixAddressLength(path: socketURL.path))
            }
        }
        guard connected == 0 else { throw ScreenshotContentError.unavailable }
        var data = try JSONEncoder().encode(request)
        data.append(0x0A)
        try DahliaTokenBrokerProtocol.writeAll(data, to: descriptor)
        let response = try JSONDecoder().decode(Response.self, from: DahliaTokenBrokerProtocol.readLine(from: descriptor))
        guard response.error == nil, (1 ... 64 * 1024 * 1024).contains(response.byteCount) else {
            throw ScreenshotContentError.unavailable
        }
        var bytes = Data(count: response.byteCount)
        try bytes.withUnsafeMutableBytes { buffer in
            var received = 0
            while received < buffer.count {
                let count = Darwin.read(descriptor, buffer.baseAddress!.advanced(by: received), buffer.count - received)
                guard count > 0 else { throw ScreenshotContentError.unavailable }
                received += count
            }
        }
        return bytes
    }

    public static func configure(_ descriptor: Int32, timeout: Int) throws {
        var noSignal: Int32 = 1
        var interval = timeval(tv_sec: timeout, tv_usec: 0)
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal))) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout.size(ofValue: interval))) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &interval, socklen_t(MemoryLayout.size(ofValue: interval))) == 0 else {
            throw POSIXError(.EIO)
        }
    }
}
