import DahliaRuntimeSupport
import Foundation

/// MCP is a public boundary; the access store and its cursor models continue to use UUIDs.
enum PublicMCPIDs {
    static func arguments(_ value: [String: Any], tool: String) throws -> [String: Any] {
        guard var result = try PublicIDWire.transform(value, shape: "mcpInput", direction: .decode) as? [String: Any] else {
            throw TypeID.Failure.invalidID
        }
        for key in ["cursor", "server_cursor"] {
            if let cursor = value[key] as? String {
                result[key] = try convertCursor(cursor, tool: tool, direction: .decode)
            }
        }
        return result
    }

    static func result(_ value: [String: Any], tool: String, arguments: [String: Any]) throws -> [String: Any] {
        guard let original = value["structuredContent"] as? [String: Any],
              var body = try PublicIDWire.transform(original, shape: "mcpResult", direction: .encode) as? [String: Any]
        else { return value }
        if let relationship = original["relationship"] as? String, relationship.hasSuffix("_resource_reference"),
           let target = original["target_id"] {
            body["target_id"] = try PublicIDWire.transform(target, shape: "resourceID", direction: .encode, parent: arguments)
        }
        if let cursor = original["next_cursor"] as? String {
            body["next_cursor"] = try convertCursor(cursor, tool: tool, direction: .encode)
        }
        if var server = body["server"] as? [String: Any] {
            if let cursor = server["next_cursor"] as? String {
                server["next_cursor"] = try convertCursor(cursor, tool: tool, direction: .encode)
            }
            if tool == "query_screenshots", let rawServer = original["server"] as? [String: Any], let items = rawServer["items"] {
                server["items"] = try PublicIDWire.transform(items, shape: "array:mcpScreenshot", direction: .encode)
            }
            body["server"] = server
        }
        var result = value
        result["structuredContent"] = body
        var content = value["content"] as? [[String: Any]] ?? []
        if !content.isEmpty {
            content[0]["text"] = try String(decoding: JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), as: UTF8.self)
        }
        result["content"] = content
        return result
    }

    private static func convertCursor(_ value: String, tool: String, direction: PublicIDWire.Direction) throws -> String {
        guard let data = Data(base64Encoded: value), var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TypeID.Failure.invalidID
        }
        var fields: [String: TypeID.Kind] = ["vaultID": .vault, "meetingID": .meeting, "segmentID": .segment, "screenshotID": .attachment]
        let kind: TypeID.Kind? = switch tool {
        case "query_contacts": .contact
        case "query_conversation_topics": .topic
        case "query_insights": .insight
        case "query_project_resources": .projectReference
        default: nil
        }
        fields["id"] = kind
        for (key, kind) in fields {
            if let value = object[key] { object[key] = try cursorID(value, kind: kind, direction: direction) }
        }
        if let position = object["position"] {
            object["position"] = try PublicIDWire.cursor(position, kind: "textSearch", direction: direction)
        }
        if let scope = object["scope"] as? String {
            object["scope"] = try convertScope(scope, tool: tool, direction: direction)
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).base64EncodedString()
    }

    private static func cursorID(_ value: Any, kind: TypeID.Kind, direction: PublicIDWire.Direction) throws -> Any {
        let converted = try PublicIDWire.id(value, kind: kind, direction: direction)
        // Codable UUIDs in the internal cursor scopes use Foundation's uppercase representation.
        if direction == .decode, let string = converted as? String { return string.uppercased() }
        return converted
    }

    private static func convertScope(_ scope: String, tool: String, direction: PublicIDWire.Direction) throws -> String {
        if tool == "query_project_resources" {
            var parts = scope.components(separatedBy: ":")
            guard parts.count == 3 else { throw TypeID.Failure.invalidID }
            parts[1] = try cursorID(parts[1], kind: .project, direction: direction) as? String ?? ""
            return parts.joined(separator: ":")
        }
        if tool == "query_meetings" || tool == "query_screenshots" {
            guard let data = Data(base64Encoded: scope), var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw TypeID.Failure.invalidID
            }
            for (key, kind) in ["projectID": TypeID.Kind.project, "topicID": .topic] {
                if let value = object[key] { object[key] = try cursorID(value, kind: kind, direction: direction) }
            }
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).base64EncodedString()
        }
        let parts = scope.components(separatedBy: ":")
        guard parts.count == 2, let data = Data(base64Encoded: parts[1]),
              var values = try JSONSerialization.jsonObject(with: data) as? [Any] else { throw TypeID.Failure.invalidID }
        if tool == "query_conversation_topics", values.count == 3 {
            values[2] = try cursorID(values[2], kind: .project, direction: direction)
        } else if tool == "query_insights", values.count == 3 {
            values[2] = try PublicIDWire.transform(values[2], shape: "resourceID", direction: direction, parent: ["resource_type": values[1]])
            if direction == .decode, let string = values[2] as? String { values[2] = string.uppercased() }
        }
        return try parts[0] + ":" + JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]).base64EncodedString()
    }
}
