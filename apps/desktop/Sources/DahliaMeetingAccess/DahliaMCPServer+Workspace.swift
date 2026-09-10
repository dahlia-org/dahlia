import DahliaRuntimeSupport
import Foundation
import GRDB

extension DahliaMCPServer {
    struct VaultAccess: Encodable {
        let id: UUID
        let name: String
        let accountType: String
        let accessState: String
        let freshness: String
    }

    private func vaults() throws -> [VaultAccess] {
        try store.database.read { db in
            let rows = try Row.fetchAll(db, sql: """
            SELECT id, name, accountConnectionId, syncConfirmedConnectionId, syncRecoveryState
            FROM vaults ORDER BY name, id
            """)
            return rows.compactMap { row in
                let id: UUID = row["id"]
                guard vaultScope == nil || vaultScope == id else { return nil }
                let connection: UUID? = row["accountConnectionId"]
                let confirmed: UUID? = row["syncConfirmedConnectionId"]
                let recovery: String? = row["syncRecoveryState"]
                return VaultAccess(
                    id: id, name: row["name"], accountType: connection == nil ? "local" : "server",
                    accessState: connection == nil ? "local" : (connection != confirmed ? "not_synced" : (recovery ?? "cached")),
                    freshness: connection == nil ? "local" : "last_synced"
                )
            }
        }
    }

    func executeTool(named name: String, arguments: [String: Any]) throws -> [String: Any] {
        if name == "list_vaults" {
            try validate(arguments, allowedKeys: [])
            return try toolResult(["vaults": vaults()])
        }
        let definitions = Self.readOnlyToolDefinitions
        guard let definition = definitions.first(where: { $0["name"] as? String == name }) else {
            return try workspaceWrite(name: name, arguments: arguments)
        }
        let schema = definition["inputSchema"] as? [String: Any]
        let keys = (schema?["properties"] as? [String: Any])?.keys.map(\.self) ?? []
        try validate(arguments, allowedKeys: Set(keys + ["vault_id"]))
        var scopedArguments = arguments
        let requestedVault = try optionalUUID(arguments, key: "vault_id")
        scopedArguments.removeValue(forKey: "vault_id")
        if let vaultScope, let requestedVault, vaultScope != requestedVault { throw MeetingAccessError.vaultNotFound }
        if let id = requestedVault ?? vaultScope {
            guard try vaults().contains(where: { $0.id == id }) else { throw MeetingAccessError.vaultNotFound }
            return try scopedRead(name: name, arguments: scopedArguments, vaultID: id)
        }
        if name.hasPrefix("get_") {
            let mapping: [String: (String, String)] = [
                "get_meeting": ("meeting_id", "meetings"),
                "get_meeting_transcript": ("meeting_id", "meetings"),
                "get_meeting_screenshots": ("meeting_id", "meetings"),
                "get_project": ("project_id", "projects"),
                "get_organization": ("organization_id", "organizations"),
                "get_contact": ("contact_id", "contacts"),
                "get_conversation_topic": ("topic_id", "conversation_topics"),
                "get_insight": ("insight_id", "insights"),
            ]
            guard let (key, table) = mapping[name] else { throw ParameterError("vault_id is required for this tool") }
            let entityID = try requiredUUID(arguments, key: key)
            let id = try store.database.read { db in
                try UUID.fetchOne(db, sql: "SELECT vaultId FROM \(table) WHERE id = ?", arguments: [entityID])
            }
            guard let id, try vaults().contains(where: { $0.id == id }) else { throw MeetingAccessError.vaultNotFound }
            return try scopedRead(name: name, arguments: scopedArguments, vaultID: id)
        }
        guard arguments["cursor"] == nil, arguments["server_cursor"] == nil else {
            throw ParameterError("Continue each vault's page with vault_id and its cursor")
        }
        var groups: [[String: Any]] = []
        for vault in try vaults() {
            do {
                let result = try scopedRead(name: name, arguments: scopedArguments, vaultID: vault.id)
                groups.append([
                    "vault_id": vault.id.uuidString.lowercased(),
                    "vault_name": vault.name,
                    "result": result["structuredContent"] ?? result,
                    "is_error": result["isError"] ?? false,
                ])
            } catch let error as ParameterError {
                throw error
            } catch {
                let code = (error as? MeetingAccessError)?.reasonCode ?? (error as? TextContentError)?
                    .rawValue ?? "unavailable"
                groups.append([
                    "vault_id": vault.id.uuidString.lowercased(),
                    "vault_name": vault.name,
                    "error": code,
                    "is_error": true,
                ])
            }
        }
        let object: [String: Any] = ["vaults": groups]
        return try [
            "content": [["type": "text", "text": String(decoding: JSONSerialization.data(withJSONObject: object), as: UTF8.self)]],
            "structuredContent": object,
            "isError": false,
        ]
    }

    private func workspaceWrite(name: String, arguments: [String: Any]) throws -> [String: Any] {
        guard let definition = Self.writeToolDefinitions.first(where: { $0["name"] as? String == name }) else {
            throw ParameterError("Unknown or disabled write tool")
        }
        guard store.allowsWrites else { throw MeetingAccessError.writeAccessRequired }
        let schema = definition["inputSchema"] as? [String: Any]
        let keys = (schema?["properties"] as? [String: Any])?.keys.map(\.self) ?? []
        try validate(arguments, allowedKeys: Set(keys + ["vault_id"]))
        var target = try optionalUUID(arguments, key: "vault_id") ?? vaultScope
        if let vaultScope, target != vaultScope { throw MeetingAccessError.vaultNotFound }
        var references = [
            "meeting_id": "meetings", "project_id": "projects", "parent_project_id": "projects",
            "organization_id": "organizations", "parent_organization_id": "organizations", "contact_id": "contacts",
            "provisional_contact_id": "contacts", "identified_contact_id": "contacts",
            "topic_id": "conversation_topics", "insight_id": "insights",
        ]
        if arguments["resource_id"] != nil {
            let tables = [
                "meeting": "meetings",
                "project": "projects",
                "organization": "organizations",
                "contact": "contacts",
                "topic": "conversation_topics",
            ]
            guard let kind = try string(arguments, key: "resource_type"), let table = tables[kind] else {
                throw ParameterError("Invalid resource_type")
            }
            references["resource_id"] = table
        }
        for (key, table) in references where arguments[key] != nil && !(arguments[key] is NSNull) {
            let id = try requiredUUID(arguments, key: key)
            guard let vaultID = try store.database.read({ db in
                try UUID.fetchOne(db, sql: "SELECT vaultId FROM \(table) WHERE id = ?", arguments: [id])
            }) else { throw key == "resource_id" ? MeetingAccessError.invalidCustomerIntelligenceReference : MeetingAccessError.vaultNotFound }
            if let target, target != vaultID { throw MeetingAccessError.invalidCustomerIntelligenceReference }
            target = vaultID
        }
        guard let target, try vaults().contains(where: { $0.id == target }) else {
            throw ParameterError("vault_id or an unambiguous parent ID is required")
        }
        var scopedArguments = arguments
        scopedArguments.removeValue(forKey: "vault_id")
        return try scopedRead(name: name, arguments: scopedArguments, vaultID: target)
    }

    private func scopedRead(name: String, arguments: [String: Any], vaultID: UUID) throws -> [String: Any] {
        let server = DahliaMCPServer(store: store.scoped(to: vaultID))
        return try server.executeScopedTool(named: name, arguments: arguments)
    }

    var workspaceToolDefinitions: [[String: Any]] {
        let reads = (Self.readOnlyToolDefinitions + (store.allowsWrites ? Self.writeToolDefinitions : [])).map { definition in
            var definition = definition
            var schema = definition["inputSchema"] as? [String: Any] ?? [:]
            var properties = schema["properties"] as? [String: Any] ?? [:]
            var vaultSchema = Self.idSchema(.vault)
            vaultSchema["description"] = "Vault scope. Required for new records unless a parent ID identifies the Vault. Cannot widen the configured scope."
            properties["vault_id"] = vaultSchema
            schema["properties"] = properties
            definition["inputSchema"] = schema
            if vaultScope == nil, (definition["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true,
               (definition["name"] as? String)?.hasPrefix("get_") != true {
                // Cross-Vault query results wrap each original result, including its own cursors and errors.
                definition.removeValue(forKey: "outputSchema")
            }
            return definition
        }
        return [[
            "name": "list_vaults",
            "description": "List vaults added to this Mac within the configured scope. Server metadata is a last-synced working copy, not proof of current server access.",
            "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false],
            "annotations": ["readOnlyHint": true],
        ]] + reads
    }
}
