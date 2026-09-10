import DahliaMeetingAccess
import DahliaRuntimeSupport
import Foundation

#if canImport(Testing)
    /// Domain fixtures remain UUID-based while requests and responses cross the production wire codec.
    enum PublicIDTestClient {
        static func internalRequest(_ request: URLRequest) throws -> URLRequest {
            guard let url = request.url, let route = PublicIDWire.route(path: url.path, method: request.httpMethod ?? "GET") else { return request }
            var result = request
            result.url = try URL(string: PublicIDWire.url(url.absoluteString, direction: .decode, method: request.httpMethod ?? "GET"))
            for (name, shape) in route.headers ?? [:] {
                if let value = request.value(forHTTPHeaderField: name) {
                    try result.setValue(PublicIDWire.transform(value, shape: shape, direction: .decode) as? String, forHTTPHeaderField: name)
                }
            }
            if let shape = route.request, let body = request.httpBody ?? request.httpBodyStream.map(read) {
                result.httpBody = try PublicIDWire.data(body, shape: shape, direction: .decode)
            }
            return result
        }

        static func publicResponse(_ data: Data, request: URLRequest, status: Int) throws -> Data {
            guard !data.isEmpty, let url = request.url,
                  let shape = PublicIDWire.route(path: url.path, method: request.httpMethod ?? "GET")?.response else { return data }
            let screenshotSearch = shape == "textSearch" && URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .contains { $0.name == "kind" && $0.value == "screenshot" } == true
            return try PublicIDWire.data(data, shape: status >= 400 ? "error" : screenshotSearch ? "textScreenshotSearch" : shape, direction: .encode)
        }

        private static func read(_ stream: InputStream) -> Data {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            return data
        }
    }

    extension DahliaMCPServer {
        func handleInternalTestLine(_ line: String) -> String? {
            guard var envelope = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  var params = envelope["params"] as? [String: Any],
                  envelope["method"] as? String == "tools/call" else { return handleLine(line) }
            if let arguments = params["arguments"], !(arguments is [String: Any]) { return handleLine(line) }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            params["arguments"] = (try? PublicIDWire.transform(arguments, shape: "mcpInput", direction: .encode)) ?? arguments
            envelope["params"] = params
            guard let data = try? JSONSerialization.data(withJSONObject: envelope),
                  let result = handleLine(String(decoding: data, as: UTF8.self)) else { return nil }
            guard var response = try? JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any],
                  var toolResult = response["result"] as? [String: Any],
                  let publicBody = toolResult["structuredContent"],
                  let internalBody = try? PublicIDWire.transform(publicBody, shape: "mcpResult", direction: .decode)
            else { return result }
            let body = restoreCasing(internalBody, original: publicBody)
            toolResult["structuredContent"] = body
            if var content = toolResult["content"] as? [[String: Any]], !content.isEmpty,
               let bytes = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) {
                content[0]["text"] = String(decoding: bytes, as: UTF8.self)
                toolResult["content"] = content
            }
            response["result"] = toolResult
            return (try? JSONSerialization.data(withJSONObject: response)).map { String(decoding: $0, as: UTF8.self) }
        }

        private func restoreCasing(_ value: Any, original: Any) -> Any {
            if let string = value as? String, string != original as? String, UUID(uuidString: string) != nil { return string.uppercased() }
            if let object = value as? [String: Any], let source = original as? [String: Any] {
                return object.reduce(into: [String: Any]()) { result, entry in
                    result[entry.key] = restoreCasing(entry.value, original: source[entry.key] ?? NSNull())
                }
            }
            if let array = value as? [Any], let source = original as? [Any] { return zip(array, source).map { restoreCasing($0, original: $1) } }
            return value
        }
    }
#endif
