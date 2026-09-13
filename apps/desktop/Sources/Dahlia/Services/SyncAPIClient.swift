import Foundation

struct SyncHTTPError: Error {
    let status: Int
    let body: Data

    var code: String? {
        (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["code"] as? String
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
            request.setValue("1", forHTTPHeaderField: "X-Dahlia-Workspace-Transfers")
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
