import DahliaServerAPI
import Foundation
import HTTPTypes
import OpenAPIRuntime
import OpenAPIURLSession
import Synchronization

extension SyncAPIClient {
    /// Retry invokes the operation again so upload bodies are recreated after token refresh.
    func perform<Value: Sendable>(
        origin: URL,
        connectionId: UUID,
        maximumBytes: Int? = nil,
        preservingJSONBody: Data? = nil,
        capture: SyncJSONResponse? = nil,
        operation: @Sendable (DahliaServerAPI.Client) async throws -> Value
    ) async throws -> Value {
        for attempt in 0 ... 1 {
            let token = try await tokenProvider(connectionId, attempt == 1)
            let client = DahliaServerAPI.Client(
                serverURL: origin, configuration: .init(dateTranscoder: SyncAPIDateTranscoder()),
                transport: URLSessionTransport(configuration: .init(session: session)),
                middlewares: [SyncAPIMiddleware(token: token, maximumBytes: maximumBytes, preservingJSONBody: preservingJSONBody, capture: capture)]
            )
            do {
                return try await operation(client)
            } catch {
                let underlying = (error as? ClientError)?.underlyingError ?? error
                if let failure = underlying as? SyncHTTPError, failure.status == 401, attempt == 0 { continue }
                throw underlying
            }
        }
        throw SyncHTTPError(status: 401, body: Data())
    }

    /// Keep exact JSON bytes: generated Optionals merge absent and null, and re-encoding changes digest inputs.
    func data(
        origin: URL,
        connectionId: UUID,
        maximumBytes: Int? = nil,
        preservingJSONBody: Data? = nil,
        operation: @Sendable (DahliaServerAPI.Client) async throws -> some Sendable
    ) async throws -> Data {
        let capture = SyncJSONResponse()
        _ = try await perform(
            origin: origin,
            connectionId: connectionId,
            maximumBytes: maximumBytes,
            preservingJSONBody: preservingJSONBody,
            capture: capture,
            operation: operation
        )
        guard let data = capture.value.withLock({ $0 }) else { throw URLError(.badServerResponse) }
        return data
    }
}

final class SyncJSONResponse: Sendable {
    let value = Mutex<Data?>(nil)
}

struct SyncAPIMiddleware: ClientMiddleware {
    let token: String
    let maximumBytes: Int?
    let preservingJSONBody: Data?
    let capture: SyncJSONResponse?

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID _: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        request.headerFields[.authorization] = "Bearer \(token)"
        request.headerFields[.init("X-Dahlia-Vault-Transfers")!] = "1"
        if let preservingJSONBody { request.headerFields[.contentLength] = String(preservingJSONBody.count) }
        let (response, body) = try await next(request, preservingJSONBody.map(HTTPBody.init) ?? body, baseURL)
        guard (200 ..< 300).contains(response.status.code) else {
            let data = if let body { try await Data(collecting: body, upTo: maximumBytes ?? Int.max) } else { Data() }
            throw SyncHTTPError(status: response.status.code, body: data)
        }
        guard capture != nil || maximumBytes != nil, let body else { return (response, body) }
        var bytes = Data()
        let limit = maximumBytes ?? Int.max
        if case let .known(length) = body.length, length > limit { throw URLError(.dataLengthExceedsMaximum) }
        for try await chunk in body {
            guard chunk.count <= limit - bytes.count else { throw URLError(.dataLengthExceedsMaximum) }
            bytes.append(contentsOf: chunk)
        }
        capture?.value.withLock { $0 = bytes }
        return (response, HTTPBody(bytes))
    }
}

struct SyncAPIDateTranscoder: DateTranscoder {
    private let fractional = ISO8601DateTranscoder.iso8601WithFractionalSeconds
    private let whole = ISO8601DateTranscoder.iso8601
    func encode(_ date: Date) throws -> String { try fractional.encode(date) }
    func decode(_ value: String) throws -> Date {
        if let date = try? fractional.decode(value) { return date }
        return try whole.decode(value)
    }
}
