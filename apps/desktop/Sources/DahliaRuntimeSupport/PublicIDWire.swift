import Foundation

/// Explicit public DTO fields. Internal Codable models, persistence and free-form metadata are unchanged.
public enum PublicIDWire {
    public enum Direction: Sendable { case encode, decode }

    public struct Route: Decodable, Sendable {
        public let path: String
        public let response: String?
        public let request: String?
        public let query: [String: String]?
        public let headers: [String: String]?
        public let methods: [String]?
    }

    private struct Contract: Decodable, Sendable {
        let shapes: [String: [String: String]]
        let routes: [Route]
    }

    private static let contract: Contract = {
        do {
            guard let url = Bundle.module.url(forResource: "PublicIDContract", withExtension: "json") else {
                preconditionFailure("Missing public ID contract")
            }
            return try JSONDecoder().decode(Contract.self, from: Data(contentsOf: url))
        } catch {
            preconditionFailure("Invalid public ID contract: \(error)")
        }
    }()

    private static let kinds: [String: TypeID.Kind] = [
        "vault": .vault, "project": .project, "meeting": .meeting, "file": .file, "attachment": .attachment,
        "summary": .summary, "transcript": .transcript, "segment": .segment, "recording": .recording,
        "event": .event, "summaryJob": .summaryJob, "contact": .contact, "topic": .topic, "insight": .insight,
        "projectReference": .projectReference, "user": .user, "organization": .organization, "team": .team,
        "organizationMember": .organizationMember, "teamMember": .teamMember, "invitation": .invitation,
        "session": .session, "transaction": .transaction, "operation": .operation, "patch": .patch,
    ]
    private static let entityKinds: [String: TypeID.Kind] = [
        "vault": .vault, "project": .project, "meeting": .meeting, "summary": .meeting, "transcript": .meeting,
        "file": .file, "meeting_attachment": .attachment, "meeting_event": .event, "recording": .recording,
    ]
    private static let recordShapes = [
        "vault": "vault", "project": "project", "meeting": "meeting", "summary": "summary", "transcript": "transcriptPatch",
        "file": "file", "meeting_attachment": "attachment", "meeting_event": "event", "recording": "recording",
    ]
    private static let resourceKinds: [String: TypeID.Kind] = [
        "meeting": .meeting, "project": .project, "contact": .contact, "topic": .topic, "conversation_topic": .topic, "insight": .insight,
        "organization": .organization,
    ]

    public static func data(_ data: Data, shape: String, direction: Direction) throws -> Data {
        let value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        let converted = try transform(value, shape: shape, direction: direction)
        return try JSONSerialization.data(withJSONObject: converted, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
    }

    public static func id(_ value: Any, kind: TypeID.Kind, direction: Direction) throws -> Any {
        if value is NSNull { return value }
        guard let string = value as? String else { throw TypeID.Failure.invalidID }
        switch direction {
        case .encode:
            guard let uuid = UUID(uuidString: string) else { throw TypeID.Failure.invalidID }
            return TypeID.encode(uuid, as: kind)
        case .decode:
            return try TypeID.decode(string, as: kind).uuidString.lowercased()
        }
    }

    public static func transform(_ value: Any, shape: String, direction: Direction, parent: [String: Any] = [:]) throws -> Any {
        if value is NSNull || shape == "pass" { return value }
        if shape.hasPrefix("id:") {
            guard let kind = kinds[String(shape.dropFirst(3))] else { throw TypeID.Failure.invalidID }
            return try id(value, kind: kind, direction: direction)
        }
        if shape.hasPrefix("array:") {
            guard let array = value as? [Any] else { throw TypeID.Failure.invalidID }
            return try array.map { try transform($0, shape: String(shape.dropFirst(6)), direction: direction) }
        }
        if shape.hasPrefix("filter:") {
            guard let field = parent["filterField"] as? String,
                  let fieldShape = contract.shapes[String(shape.dropFirst(7))]?[field], fieldShape.hasPrefix("id:") else { return value }
            return try transform(value, shape: fieldShape, direction: direction)
        }
        if shape.hasPrefix("cursor:") { return try cursor(value, kind: String(shape.dropFirst(7)), direction: direction) }
        if shape == "url", let string = value as? String { return try url(string, direction: direction) }
        if shape == "urls", let urls = value as? [String: String] {
            return try urls.mapValues { try url($0, direction: direction) }
        }
        if shape == "teamList", let string = value as? String {
            return try string.components(separatedBy: ",").map { try String(describing: id($0, kind: .team, direction: direction)) }
                .joined(separator: ",")
        }
        if shape == "teamChoice" {
            if let values = value as? [Any] { return try values.map { try id($0, kind: .team, direction: direction) } }
            return try id(value, kind: .team, direction: direction)
        }
        if shape == "document" { return try document(value, direction: direction) }
        return try contextualValue(value, shape: shape, direction: direction, parent: parent)
    }

    private static func contextualValue(_ value: Any, shape: String, direction: Direction, parent: [String: Any]) throws -> Any {
        if shape == "personalWorkspace" {
            guard let string = value as? String, string.hasPrefix("personal:") else { throw TypeID.Failure.invalidID }
            return try "personal:\(id(String(string.dropFirst(9)), kind: .user, direction: direction))"
        }
        if shape == "memberOrEmail" {
            if let string = value as? String, string.contains("@") { return string }
            return try id(value, kind: .organizationMember, direction: direction)
        }
        if shape == "resourceID" {
            let type = (parent["resource_type"] ?? parent["resourceType"]) as? String
            guard let type, let kind = resourceKinds[type] else { throw TypeID.Failure.invalidID }
            return try id(value, kind: kind, direction: direction)
        }
        if shape == "textEntityID" {
            return try id(value, kind: parent["entity"] as? String == "file" ? .file : .meeting, direction: direction)
        }
        if shape == "relationshipSource" || shape == "relationshipTarget" {
            let resource = resourceKinds[parent["resource_type"] as? String ?? ""]
            let mapping: [String: (TypeID.Kind?, TypeID.Kind?)] = [
                "organization_domain": (.organization, nil), "contact_organization_membership": (.contact, .organization),
                "project_resource_reference": (.project, resource), "conversation_topic_resource_reference": (.topic, resource),
                "insight_resource_reference": (.insight, resource), "meeting_project_assignment": (.meeting, .project),
            ]
            let pair = mapping[parent["relationship"] as? String ?? ""]
            let kind = shape == "relationshipSource" ? pair?.0 : pair?.1
            return try kind.map { try id(value, kind: $0, direction: direction) } ?? value
        }
        return try objectValue(value, shape: shape, direction: direction)
    }

    private static func objectValue(_ value: Any, shape: String, direction: Direction) throws -> Any {
        guard let object = value as? [String: Any] else { return value }
        var result = object
        if shape == "canonical" || shape == "operation" { return try syncValue(object, shape: shape, direction: direction) }
        if shape == "permission" {
            if let type = object["principalType"] as? String, let kind = kinds[type], let value = object["principalId"] {
                result["principalId"] = try id(value, kind: kind, direction: direction)
            }
            for (key, kind) in ["vaultId": TypeID.Kind.vault, "grantedByUserId": .user] {
                if let value = object[key] { result[key] = try id(value, kind: kind, direction: direction) }
            }
            return result
        }
        if shape == "textSearchHit" {
            for key in ["id", "sourceId", "source_id"] {
                if let value = object[key] { result[key] = try id(
                    value,
                    kind: object["kind"] as? String == "screenshot" ? .attachment : .meeting,
                    direction: direction
                ) }
            }
            for key in ["meetingId", "meeting_id"] {
                if let value = object[key] { result[key] = try id(value, kind: .meeting, direction: direction) }
            }
            return result
        }
        guard let fields = contract.shapes[shape] else { throw TypeID.Failure.invalidID }
        for (key, field) in fields {
            if let value = object[key] { result[key] = try transform(value, shape: field, direction: direction, parent: object) }
        }
        if shape == "event", object["kind"] as? String == "segment_rotated", let value = object["relatedId"] {
            result["relatedId"] = try id(value, kind: .segment, direction: direction)
        }
        // Other result shapes can carry errors too; the error shape already converted these fields.
        if shape != "error", object["error"] != nil {
            if let value = object["conflicts"] { result["conflicts"] = try transform(value, shape: "array:canonical", direction: direction) }
            if let value = object["operationId"] { result["operationId"] = try id(value, kind: .operation, direction: direction) }
        }
        return result
    }

    private static func syncValue(_ object: [String: Any], shape: String, direction: Direction) throws -> Any {
        var result = object
        guard let entity = object["entity"] as? String, let kind = entityKinds[entity], let record = recordShapes[entity] else {
            throw TypeID.Failure.invalidID
        }
        for key in ["id", "entityId"] {
            if let value = object[key] { result[key] = try id(
                value,
                kind: key == "id" && shape == "operation" ? .operation : kind,
                direction: direction
            ) }
        }
        for (key, kind) in ["vaultId": TypeID.Kind.vault, "transactionId": .transaction, "operationId": .operation] {
            if let value = object[key] { result[key] = try id(value, kind: kind, direction: direction) }
        }
        for key in ["data", "record"] {
            if let value = object[key] { result[key] = try transform(value, shape: record, direction: direction) }
        }
        return result
    }

    public static func cursor(_ value: Any, kind: String, direction: Direction) throws -> Any {
        if value is NSNull { return value }
        guard let string = value as? String else { throw TypeID.Failure.invalidID }
        if kind == "textSearch" {
            guard var parts = try JSONSerialization.jsonObject(with: Data(string.utf8)) as? [Any],
                  parts.count == 5 else { throw TypeID.Failure.invalidID }
            parts[0] = try id(parts[0], kind: .vault, direction: direction)
            return try String(decoding: JSONSerialization.data(withJSONObject: parts, options: [.withoutEscapingSlashes]), as: UTF8.self)
        }
        if kind == "file" || kind == "attachment" { return try id(string, kind: kind == "file" ? .file : .attachment, direction: direction) }
        let parts = string.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2,
              let type = kind == "snapshot" ? entityKinds[parts[0]] : kind == "screenshot" ? .attachment : kinds[kind]
        else { throw TypeID.Failure.invalidID }
        return try "\(parts[0]),\(id(parts[1], kind: type, direction: direction))"
    }

    public static func route(path: String, method: String = "GET") -> Route? {
        let parts = path.components(separatedBy: "/")
        return contract.routes.first { route in
            if let methods = route.methods, !methods.contains(method) { return false }
            let template = route.path.components(separatedBy: "/")
            return template.count == parts.count && zip(template, parts).allSatisfy { $0.hasPrefix(":") ? !$1.isEmpty : $0 == $1 }
        }
    }

    public static func url(_ string: String, direction: Direction, method: String = "GET") throws -> String {
        guard var components = URLComponents(string: string), let route = route(
            path: components.path.hasPrefix("/") ? components.path : "/" + components.path,
            method: method
        ) else { return string }
        let relative = !components.path.hasPrefix("/")
        var parts = (relative ? "/" + components.path : components.path).components(separatedBy: "/")
        for (index, part) in route.path.components(separatedBy: "/").enumerated() {
            if part.hasPrefix(":"), let kind = kinds[String(part.dropFirst())] {
                guard let identifier = try id(parts[index], kind: kind, direction: direction) as? String else {
                    throw TypeID.Failure.invalidID
                }
                parts[index] = identifier
            }
        }
        components.path = parts.joined(separator: "/")
        if relative { components.path.removeFirst() }
        if let items = components.queryItems {
            let query = items.reduce(into: [String: Any]()) { $0[$1.name] = $1.value }
            components.queryItems = try items.map { item in
                guard let shape = route.query?[item.name], let value = item.value else { return item }
                return try URLQueryItem(name: item.name, value: transform(value, shape: shape, direction: direction, parent: query) as? String)
            }
        }
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let result = components.string else { throw TypeID.Failure.invalidID }
        return result
    }

    /// Only image-reference string tokens are replaced. This preserves stored JSON formatting for content hashes.
    public static func document(_ value: Any, direction: Direction) throws -> Any {
        let serialized = value is String
        let source: String = if let string = value as? String {
            string
        } else {
            try String(
                decoding: JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]),
                as: UTF8.self
            )
        }
        guard (try? JSONSerialization.jsonObject(with: Data(source.utf8), options: [.fragmentsAllowed])) != nil else { return value }
        let regex = try NSRegularExpression(pattern: #""(?:\\.|[^"\\])*"|[{}\[\]:,]|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|true|false|null"#)
        let text = source as NSString
        let tokens = regex.matches(in: source, range: NSRange(location: 0, length: text.length))
        var index = 0
        var edits: [(NSRange, String)] = []
        func token(_ index: Int) -> String { index < tokens.count ? text.substring(with: tokens[index].range) : "" }
        func walk(_ path: [String]) throws {
            guard index < tokens.count else { throw TypeID.Failure.invalidID }
            let current = index
            let value = token(index)
            index += 1
            if value == "{" {
                while token(index) != "}" {
                    guard let key = try JSONSerialization.jsonObject(with: Data(token(index).utf8), options: [.fragmentsAllowed]) as? String
                    else { throw TypeID.Failure.invalidID }
                    index += 2
                    try walk(path + [key])
                    if token(index) != "," { break }
                    index += 1
                }
                index += 1
            } else if value == "[" {
                while token(index) != "]" {
                    try walk(path + ["*"])
                    if token(index) != "," { break }
                    index += 1
                }
                index += 1
            } else if ["sections.*.blocks.*.screenshot_id", "sections.*.blocks.*.screenshotId"].contains(path.joined(separator: ".")) {
                let original = try JSONSerialization.jsonObject(with: Data(value.utf8), options: [.fragmentsAllowed])
                let converted = try id(original, kind: .attachment, direction: direction)
                let data = try JSONSerialization.data(withJSONObject: converted, options: [.fragmentsAllowed])
                edits.append((tokens[current].range, String(decoding: data, as: UTF8.self)))
            }
        }
        try walk([])
        let result = NSMutableString(string: source)
        for (range, replacement) in edits.reversed() {
            result.replaceCharacters(in: range, with: replacement)
        }
        if serialized { return result as String }
        return try JSONSerialization.jsonObject(with: Data((result as String).utf8), options: [.fragmentsAllowed])
    }
}

public extension PublicIDWire {
    static func request(_ internalRequest: URLRequest) throws -> URLRequest {
        guard let originalURL = internalRequest.url else { throw URLError(.badURL) }
        let method = internalRequest.httpMethod ?? "GET"
        guard let route = route(path: originalURL.path, method: method) else { return internalRequest }
        var request = internalRequest
        request.url = try URL(string: url(originalURL.absoluteString, direction: .encode, method: method))
        for (key, shape) in route.headers ?? [:] {
            if let value = request.value(forHTTPHeaderField: key) {
                try request.setValue(transform(value, shape: shape, direction: .encode) as? String, forHTTPHeaderField: key)
            }
        }
        if let body = request.httpBody, let shape = route.request {
            request.httpBody = try data(body, shape: shape, direction: .encode)
            request.setValue(nil, forHTTPHeaderField: "Content-Length")
        }
        return request
    }

    static func response(_ publicData: Data, request: URLRequest, status: Int = 200) throws -> Data {
        guard !publicData.isEmpty, let path = request.url?.path,
              let contract = route(path: path, method: request.httpMethod ?? "GET") else { return publicData }
        if status >= 400 { return try data(publicData, shape: "error", direction: .decode) }
        guard let shape = contract.response else { return publicData }
        if shape == "textSearch", request.httpMethod == "POST", let body = request.httpBody,
           let arguments = try JSONSerialization.jsonObject(with: body) as? [String: Any],
           arguments["kind"] as? String == "screenshot" {
            return try data(publicData, shape: "textScreenshotSearch", direction: .decode)
        }
        let screenshotSearch = shape == "textSearch" && URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
            .contains { $0.name == "kind" && $0.value == "screenshot" } == true
        return try data(publicData, shape: screenshotSearch ? "textScreenshotSearch" : shape, direction: .decode)
    }
}
