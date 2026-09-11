import DahliaRuntimeSupport
import Foundation

/// MCP is a public boundary; the access store and its cursor models continue to use UUIDs.
enum PublicMCPIDs {
    static func arguments(_ value: [String: Any], tool: String) throws -> [String: Any] {
        let optionalStringKeys: Set = [
            "query", "project", "project_id", "ical_uid",
            "created_from", "created_before", "cursor", "server_cursor",
        ]
        let arguments = value.filter { key, value in
            guard tool == "query_meetings", optionalStringKeys.contains(key), let string = value as? String else { return true }
            return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard var result = try PublicIDWire.transform(arguments, shape: "mcpInput", direction: .decode) as? [String: Any] else {
            throw TypeID.Failure.invalidID
        }
        for key in ["cursor", "server_cursor"] {
            if let cursor = arguments[key] as? String {
                result[key] = try convertCursor(cursor, tool: tool, direction: .decode)
            }
        }
        return result
    }

    static func result(_ value: [String: Any], tool: String, arguments: [String: Any]) throws -> [String: Any] {
        guard let original = value["structuredContent"] as? [String: Any] else { return value }
        let shape = switch tool {
        case "list_vaults": "mcpVaultList"
        default: "mcpResult"
        }
        guard var body = try PublicIDWire.transform(original, shape: shape, direction: .encode) as? [String: Any] else { return value }
        if tool != "list_vaults", let groups = original["vaults"] as? [[String: Any]] {
            body["vaults"] = try groups.map { group in
                var converted = group
                if let id = group["vault_id"] { converted["vault_id"] = try PublicIDWire.id(id, kind: .vault, direction: .encode) }
                if let nested = group["result"] as? [String: Any] {
                    converted["result"] = try Self.result(["structuredContent": nested], tool: tool, arguments: arguments)["structuredContent"]
                }
                return converted
            }
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
        let fields: [String: TypeID.Kind] = ["vaultID": .vault, "meetingID": .meeting, "segmentID": .segment, "screenshotID": .attachment]
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
        if tool == "query_meetings" || tool == "query_screenshots" {
            guard let data = Data(base64Encoded: scope), var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw TypeID.Failure.invalidID
            }
            if let value = object["projectID"] {
                object["projectID"] = try cursorID(value, kind: .project, direction: direction)
            }
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).base64EncodedString()
        }
        return scope
    }
}
