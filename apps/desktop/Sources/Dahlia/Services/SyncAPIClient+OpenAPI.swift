import DahliaRuntimeSupport
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
        let method = request.method.rawValue
        guard let internalURL = URL(string: request.path ?? "/", relativeTo: baseURL)?.absoluteURL else {
            throw URLError(.badURL)
        }
        let route = PublicIDWire.route(path: internalURL.path, method: method)
        guard let publicURL = try URL(string: PublicIDWire.url(internalURL.absoluteString, direction: .encode, method: method)) else {
            throw URLError(.badURL)
        }
        request.path = publicURL.path + (publicURL.query.map { "?\($0)" } ?? "")
        for (name, shape) in route?.headers ?? [:] {
            guard let field = HTTPField.Name(name), let value = request.headerFields[field] else { continue }
            request.headerFields[field] = try PublicIDWire.transform(value, shape: shape, direction: .encode) as? String
        }
        request.headerFields[.authorization] = "Bearer \(token)"
        request.headerFields[.init("X-Dahlia-Vault-Transfers")!] = "1"
        var responseShape = route?.response
        let internalBody = preservingJSONBody.map(HTTPBody.init) ?? body
        let publicBody: HTTPBody?
        if let shape = route?.request, let internalBody {
            let data = try await Data(collecting: internalBody, upTo: 64 * 1024 * 1024)
            if responseShape == "textSearch",
               let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               request["kind"] as? String == "screenshot" {
                responseShape = "textScreenshotSearch"
            }
            let converted = try PublicIDWire.data(data, shape: shape, direction: .encode)
            request.headerFields[.contentLength] = String(converted.count)
            publicBody = HTTPBody(converted)
        } else {
            publicBody = internalBody
            if let preservingJSONBody { request.headerFields[.contentLength] = String(preservingJSONBody.count) }
        }
        var (response, responseBody) = try await next(request, publicBody, baseURL)
        if let location = response.headerFields[.location] {
            response.headerFields[.location] = try PublicIDWire.url(location, direction: .decode)
        }
        guard (200 ..< 300).contains(response.status.code) else {
            let data = if let responseBody { try await Data(collecting: responseBody, upTo: maximumBytes ?? Int.max) } else { Data() }
            let decoded = (try? PublicIDWire.data(data, shape: "error", direction: .decode)) ?? data
            throw SyncHTTPError(status: response.status.code, body: decoded)
        }
        let isJSON = response.headerFields[.contentType].map { $0.contains("json") } ?? true
        if let shape = responseShape, isJSON, let publicResponseBody = responseBody {
            let data = try await Data(collecting: publicResponseBody, upTo: maximumBytes ?? Int.max)
            let screenshotSearch = shape == "textSearch" && internalURL.query?.contains("kind=screenshot") == true
            let converted = try PublicIDWire.data(data, shape: screenshotSearch ? "textScreenshotSearch" : shape, direction: .decode)
            responseBody = HTTPBody(converted)
            response.headerFields[.contentLength] = String(converted.count)
        }
        guard capture != nil || maximumBytes != nil, let responseBody else { return (response, responseBody) }
        var bytes = Data()
        let limit = maximumBytes ?? Int.max
        if case let .known(length) = responseBody.length, length > limit { throw URLError(.dataLengthExceedsMaximum) }
        for try await chunk in responseBody {
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
