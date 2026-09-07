import Foundation

struct SyncHTTPError: Error {
    let status: Int
    let body: Data

    var code: String? {
        (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? String
    }

    var blockedReason: SyncBlockedReason? {
        switch status {
        case 401, 403: .authorization
        case 409: .conflict
        case 400 ..< 500 where ![408, 425, 429].contains(status): .validation
        default: nil
        }
    }
}

struct SyncAPIClient: Sendable {
    let session: URLSession
    var tokenProvider: @Sendable (UUID, Bool) async throws -> String = {
        try await DahliaCloudTokenServiceRegistry.shared.validAccessToken(connectionID: $0, forceRefresh: $1)
    }

    func data(for unsigned: URLRequest, connectionId: UUID, maximumBytes: Int? = nil) async throws -> Data {
        for attempt in 0 ... 1 {
            var request = unsigned
            let token = try await tokenProvider(connectionId, attempt == 1)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let data: Data
            let response: URLResponse
            if let maximumBytes {
                let (stream, received) = try await session.bytes(for: request)
                guard received.expectedContentLength <= maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
                var buffer = Data()
                for try await byte in stream {
                    guard buffer.count < maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
                    buffer.append(byte)
                }
                data = buffer
                response = received
            } else {
                (data, response) = try await session.data(for: request)
            }
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if (200 ..< 300).contains(http.statusCode) { return data }
            if http.statusCode == 401, attempt == 0 { continue }
            throw SyncHTTPError(status: http.statusCode, body: data)
        }
        throw SyncHTTPError(status: 401, body: Data())
    }
}

extension SyncAPIClient {
    func upload(_ unsigned: URLRequest, from file: URL, connectionId: UUID) async throws -> Data {
        for attempt in 0 ... 1 {
            var request = unsigned
            try await request.setValue("Bearer \(tokenProvider(connectionId, attempt == 1))", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.upload(for: request, fromFile: file)
            guard let http = response as? HTTPURLResponse, data.count <= 1024 * 1024 else { throw URLError(.badServerResponse) }
            if (200 ..< 300).contains(http.statusCode) { return data }
            if http.statusCode == 401, attempt == 0 { continue }
            throw SyncHTTPError(status: http.statusCode, body: data)
        }
        throw URLError(.userAuthenticationRequired)
    }

    /// URLSession streams to its temporary file; audio never becomes an in-memory Data value.
    func download(_ unsigned: URLRequest, connectionId: UUID, expectedSize: Int64) async throws -> URL {
        for attempt in 0 ... 1 {
            var request = unsigned
            try await request.setValue("Bearer \(tokenProvider(connectionId, attempt == 1))", forHTTPHeaderField: "Authorization")
            let (url, response) = try await session.download(for: request, delegate: RecordingDownloadLimit(expectedSize: expectedSize))
            guard let http = response as? HTTPURLResponse else {
                try? FileManager.default.removeItem(at: url)
                throw URLError(.badServerResponse)
            }
            if http.statusCode == 200 {
                do {
                    guard http.mimeType == "audio/mp4", try RecordingArchiveEncoder.fileSize(url) == expectedSize else {
                        throw RecordingAudioStoreError.integrityMismatch
                    }
                    return url
                } catch {
                    try? FileManager.default.removeItem(at: url)
                    throw error
                }
            }
            try? FileManager.default.removeItem(at: url)
            if http.statusCode == 401, attempt == 0 { continue }
            throw SyncHTTPError(status: http.statusCode, body: Data())
        }
        throw URLError(.userAuthenticationRequired)
    }
}

/// Immutable per-download bound; URLSession invokes callbacks on its delegate queue.
private final class RecordingDownloadLimit: NSObject, URLSessionDownloadDelegate, Sendable {
    let expectedSize: Int64
    init(expectedSize: Int64) { self.expectedSize = expectedSize }

    func urlSession(
        _: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesWritten > expectedSize || (totalBytesExpectedToWrite >= 0 && totalBytesExpectedToWrite != expectedSize) {
            downloadTask.cancel()
        }
    }

    func urlSession(_: URLSession, downloadTask _: URLSessionDownloadTask, didFinishDownloadingTo _: URL) {}
}
