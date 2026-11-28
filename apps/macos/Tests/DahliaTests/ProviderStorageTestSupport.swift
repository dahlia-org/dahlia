import Foundation
import Synchronization
@testable import Dahlia

#if canImport(Testing)
    /// Answers each test's requests by host, so suites running in parallel never share handlers or logs.
    final class StorageStubURLProtocol: URLProtocol, @unchecked Sendable {
        struct Response: Sendable {
            var status = 200
            var headers: [String: String] = [:]
            var body = Data()

            static func json(_ text: String, status: Int = 200) -> Self { Self(status: status, body: Data(text.utf8)) }
        }

        typealias Handler = @Sendable (URLRequest) -> Response
        // Foundation calls the protocol on its own threads; the mutexes own all shared state.
        private static let handlers = Mutex<[String: Handler]>([:])
        private static let logs = Mutex<[String: [URLRequest]]>([:])

        static func session(host: String, handler: @escaping Handler) -> URLSession {
            handlers.withLock { $0[host] = handler }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [Self.self]
            return URLSession(configuration: configuration)
        }

        static func requests(host: String) -> [URLRequest] { logs.withLock { $0[host] ?? [] } }

        static func reset(host: String) {
            handlers.withLock { $0[host] = nil }
            logs.withLock { $0[host] = nil }
        }

        /// A request body, which Foundation hands to the protocol as a stream.
        static func body(_ request: URLRequest) -> Data {
            if let body = request.httpBody { return body }
            guard let stream = request.httpBodyStream else { return Data() }
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            return data
        }

        override static func canInit(with _: URLRequest) -> Bool { true }
        override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let url = request.url!
            let host = url.host() ?? ""
            var logged = request
            logged.httpBody = Self.body(request)
            Self.logs.withLock { $0[host, default: []].append(logged) }
            let response = Self.handlers.withLock { $0[host] }?(logged) ?? Response(status: 599)
            client?.urlProtocol(
                self,
                didReceive: HTTPURLResponse(url: url, statusCode: response.status, httpVersion: nil, headerFields: response.headers)!,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: response.body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    extension URLRequest {
        func query(_ name: String) -> String? {
            url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?.first { $0.name == name }?.value
        }

        var jsonBody: [String: Any] {
            (try? JSONSerialization.jsonObject(with: httpBody ?? Data())) as? [String: Any] ?? [:]
        }
    }

    func temporaryBackupFile(named name: String = "Dahlia-\(UUID.v7()).tar.gz", contents: String = "archive") throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "storage-\(UUID.v7())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        try Data(contents.utf8).write(to: url)
        return url
    }
#endif
