import DahliaRuntimeSupport
import Foundation
import GRDB

extension DahliaMCPServer {
    struct WorkspaceAccess: Encodable {
        let id: UUID
        let name: String
        let accountType: String
        let accountID: String
        let accessState: String
        let freshness: String
    }

    struct MeetingBatch: Encodable {
        struct Failure: Encodable {
            let index: Int
            let id: String
            let code: String
        }

        let meetings: [MeetingDetail]
        let errors: [Failure]
    }

    private func workspaces() throws -> [WorkspaceAccess] {
        try store.database.read { db in
            try store.accountScope?.validate(in: db)
            let rows = try Row.fetchAll(db, sql: """
            SELECT id, name, accountConnectionId, syncConfirmedConnectionId, syncRecoveryState
            FROM workspaces ORDER BY name, id
            """)
            return rows.compactMap { row in
                let id: UUID = row["id"]
                guard workspaceScope == nil || workspaceScope == id,
                      store.accountScope?.contains(row) != false else { return nil }
                let connection: UUID? = row["accountConnectionId"]
                let confirmed: UUID? = row["syncConfirmedConnectionId"]
                let recovery: String? = row["syncRecoveryState"]
                return WorkspaceAccess(
                    id: id, name: row["name"], accountType: connection == nil ? "local" : "server",
                    accountID: connection?.uuidString.lowercased() ?? "local",
                    accessState: connection == nil ? "local" : (connection != confirmed ? "not_synced" : (recovery ?? "cached")),
                    freshness: connection == nil ? "local" : "last_synced"
                )
            }
        }
    }

    func executeTool(named name: String, arguments: [String: Any]) throws -> [String: Any] {
        if name == "list_workspaces" {
            try validate(arguments, allowedKeys: [])
            return try toolResult(["workspaces": workspaces()])
        }
        if name == "get_meetings" { return try toolResult(getMeetings(arguments)) }
        let definitions = Self.readOnlyToolDefinitions
        guard let definition = definitions.first(where: { $0["name"] as? String == name }) else {
            return try workspaceWrite(name: name, arguments: arguments)
        }
        let schema = definition["inputSchema"] as? [String: Any]
        let keys = (schema?["properties"] as? [String: Any])?.keys.map(\.self) ?? []
        try validate(arguments, allowedKeys: Set(keys + ["workspace_id"]))
        var scopedArguments = arguments
        let requestedWorkspace = try optionalUUID(arguments, key: "workspace_id")
        scopedArguments.removeValue(forKey: "workspace_id")
        if let workspaceScope, let requestedWorkspace, workspaceScope != requestedWorkspace { throw MeetingAccessError.workspaceNotFound }
        if let id = requestedWorkspace ?? workspaceScope {
            guard try workspaces().contains(where: { $0.id == id }) else { throw MeetingAccessError.workspaceNotFound }
            return try scopedRead(name: name, arguments: scopedArguments, workspaceID: id)
        }
        if name.hasPrefix("get_") {
            let mapping: [String: (String, String)] = [
                "get_meeting_transcript": ("meeting_id", "meetings"),
                "get_meeting_screenshots": ("meeting_id", "meetings"),
                "get_project": ("project_id", "projects"),
            ]
            guard let (key, table) = mapping[name] else { throw ParameterError("workspace_id is required for this tool") }
            let entityID = try requiredUUID(arguments, key: key)
            let id = try store.database.read { db in
                try UUID.fetchOne(db, sql: "SELECT workspace_id FROM \(table) WHERE id = ?", arguments: [entityID])
            }
            guard let id, try workspaces().contains(where: { $0.id == id }) else { throw MeetingAccessError.workspaceNotFound }
            return try scopedRead(name: name, arguments: scopedArguments, workspaceID: id)
        }
        guard arguments["cursor"] == nil, arguments["server_cursor"] == nil else {
            throw ParameterError("Continue each workspace's page with workspace_id and its cursor")
        }
        var groups: [[String: Any]] = []
        for workspace in try workspaces() {
            do {
                let result = try scopedRead(name: name, arguments: scopedArguments, workspaceID: workspace.id)
                groups.append([
                    "workspace_id": workspace.id.uuidString.lowercased(),
                    "workspace_name": workspace.name,
                    "result": result["structuredContent"] ?? result,
                    "is_error": result["isError"] ?? false,
                ])
            } catch let error as ParameterError {
                throw error
            } catch {
                let code = (error as? MeetingAccessError)?.reasonCode ?? (error as? TextContentError)?
                    .rawValue ?? "unavailable"
                groups.append([
                    "workspace_id": workspace.id.uuidString.lowercased(),
                    "workspace_name": workspace.name,
                    "error": code,
                    "is_error": true,
                ])
            }
        }
        let object: [String: Any] = ["workspaces": groups]
        return try [
            "content": [["type": "text", "text": String(decoding: JSONSerialization.data(withJSONObject: object), as: UTF8.self)]],
            "structuredContent": object,
            "isError": false,
        ]
    }

    /// Each ID resolves to its own Workspace, so one call may span Workspaces. `workspace_id` or the configured scope
    /// narrows the call; IDs outside it are reported as not_found.
    private func getMeetings(_ arguments: [String: Any]) throws -> MeetingBatch {
        try validate(arguments, allowedKeys: ["meeting_ids", "summary_format", "workspace_id"])
        let requestedWorkspace = try optionalUUID(arguments, key: "workspace_id")
        if let workspaceScope, let requestedWorkspace, workspaceScope != requestedWorkspace { throw MeetingAccessError.workspaceNotFound }
        let structured = switch try string(arguments, key: "summary_format") ?? "markdown" {
        case "markdown": false
        case "structured": true
        default: throw ParameterError("summary_format must be markdown or structured")
        }
        guard let ids = arguments["meeting_ids"] as? [Any], (1 ... Self.maximumMeetingCount).contains(ids.count),
              let rawIDs = ids as? [String] else {
            throw ParameterError("meeting_ids must be an array of 1 to \(Self.maximumMeetingCount) meeting TypeID strings")
        }
        guard Set(rawIDs).count == rawIDs.count else { throw ParameterError("meeting_ids must not contain duplicates") }
        var visible = try Set(workspaces().map(\.id))
        if let requestedWorkspace {
            guard visible.contains(requestedWorkspace) else { throw MeetingAccessError.workspaceNotFound }
            visible = [requestedWorkspace]
        }

        var meetings: [MeetingDetail] = []
        var errors: [MeetingBatch.Failure] = []
        for (index, rawID) in rawIDs.enumerated() {
            let code: String
            // meeting_ids stay as sent through PublicMCPIDs so one invalid ID is reported here instead of failing the call.
            if let meetingID = try? TypeID.decode(rawID, as: .meeting) {
                do {
                    let workspaceID = try store.database.read { db in
                        try UUID.fetchOne(db, sql: "SELECT workspace_id FROM meetings WHERE id = ?", arguments: [meetingID])
                    }
                    guard let workspaceID, visible.contains(workspaceID) else { throw MeetingAccessError.meetingNotFound }
                    var detail = try store.scoped(to: workspaceID).meeting(id: meetingID)
                    if structured {
                        detail.summary = nil
                    } else {
                        detail.structuredSummary = nil
                        detail.summaryVersion = nil
                    }
                    meetings.append(detail)
                    continue
                } catch MeetingAccessError.invalidSummaryDocument {
                    code = "unreadable"
                } catch let error as MeetingAccessError where error.reasonCode == "not_found" {
                    code = "not_found"
                } catch let error as DatabaseError {
                    throw error
                } catch {
                    code = "unavailable"
                }
            } else {
                code = "invalid_id"
            }
            errors.append(.init(index: index, id: rawID, code: code))
        }
        return MeetingBatch(meetings: meetings, errors: errors)
    }

    private func workspaceWrite(name: String, arguments: [String: Any]) throws -> [String: Any] {
        guard let definition = Self.writeToolDefinitions.first(where: { $0["name"] as? String == name }) else {
            throw ParameterError("Unknown or disabled write tool")
        }
        guard store.allowsWrites else { throw MeetingAccessError.writeAccessRequired }
        let schema = definition["inputSchema"] as? [String: Any]
        let keys = (schema?["properties"] as? [String: Any])?.keys.map(\.self) ?? []
        try validate(arguments, allowedKeys: Set(keys + ["workspace_id"]))
        var target = try optionalUUID(arguments, key: "workspace_id") ?? workspaceScope
        if let workspaceScope, target != workspaceScope { throw MeetingAccessError.workspaceNotFound }
        let references = [
            "meeting_id": "meetings", "project_id": "projects", "parent_project_id": "projects",
        ]
        for (key, table) in references where arguments[key] != nil && !(arguments[key] is NSNull) {
            let id = try requiredUUID(arguments, key: key)
            guard let workspaceID = try store.database.read({ db in
                try UUID.fetchOne(db, sql: "SELECT workspace_id FROM \(table) WHERE id = ?", arguments: [id])
            }) else { throw MeetingAccessError.workspaceNotFound }
            if let target, target != workspaceID { throw MeetingAccessError.workspaceNotFound }
            target = workspaceID
        }
        guard let target, try workspaces().contains(where: { $0.id == target }) else {
            throw ParameterError("workspace_id or an unambiguous parent ID is required")
        }
        var scopedArguments = arguments
        scopedArguments.removeValue(forKey: "workspace_id")
        return try scopedRead(name: name, arguments: scopedArguments, workspaceID: target)
    }

    private func scopedRead(name: String, arguments: [String: Any], workspaceID: UUID) throws -> [String: Any] {
        let server = DahliaMCPServer(store: store.scoped(to: workspaceID))
        server.transcriptWaitTimeout = transcriptWaitTimeout
        return try server.executeScopedTool(named: name, arguments: arguments)
    }

    var workspaceToolDefinitions: [[String: Any]] {
        let reads = (Self.readOnlyToolDefinitions + (store.allowsWrites ? Self.writeToolDefinitions : [])).map { definition in
            var definition = definition
            var schema = definition["inputSchema"] as? [String: Any] ?? [:]
            var properties = schema["properties"] as? [String: Any] ?? [:]
            var workspaceSchema = Self.idSchema(.workspace)
            workspaceSchema["description"] = "Workspace scope. Required for new records unless a parent ID identifies the Workspace. Cannot widen the configured scope."
            properties["workspace_id"] = workspaceSchema
            schema["properties"] = properties
            definition["inputSchema"] = schema
            if workspaceScope == nil, (definition["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true,
               (definition["name"] as? String)?.hasPrefix("get_") != true {
                // Cross-Workspace query results wrap each original result, including its own cursors and errors.
                definition.removeValue(forKey: "outputSchema")
            }
            return definition
        }
        return [[
            "name": "list_workspaces",
            "description": "List workspaces added to this Mac within the configured scope. Server metadata is a last-synced working copy, not proof of current server access.",
            "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false],
            "annotations": ["readOnlyHint": true],
        ]] + reads
    }
}
