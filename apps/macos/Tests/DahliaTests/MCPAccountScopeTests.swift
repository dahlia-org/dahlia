import Foundation
import GRDB
@testable import Dahlia
@testable import DahliaMeetingAccess
@testable import DahliaRuntimeSupport

#if canImport(Testing)
    import Testing

    struct MCPCommandLineOptionsTests {
        @Test
        func acceptsAccountWorkspaceAndDefaultScopes() throws {
            let id = UUID.v7()
            let defaults = try MCPCommandLineOptions(arguments: [])
            #expect(defaults.accountScope == nil)
            #expect(defaults.workspaceID == nil)
            #expect(!defaults.allowsWrites)
            let local = try MCPCommandLineOptions(arguments: ["--account", "local", "--write"])
            #expect(local.accountScope == .local)
            #expect(local.allowsWrites)
            let account = try MCPCommandLineOptions(arguments: ["--account", id.uuidString])
            #expect(account.accountScope == .account(id))
            for flag in ["--workspace", "--workspace-id"] {
                let workspace = try MCPCommandLineOptions(arguments: [flag, TypeID.encode(id, as: .workspace)])
                #expect(workspace.workspaceID == id)
            }
            let chat = try MCPCommandLineOptions(arguments: ["--telemetry-origin", "codexChat"])
            #expect(chat.telemetryOrigin == .codexChat)
        }

        @Test(arguments: [
            ["--account"], ["--account", ""], ["--account", "invalid"],
            ["--account", "local", "--account", "local"],
            ["--workspace"], ["--write", "--write"], ["--unknown"],
        ])
        func rejectsMalformedOrRepeatedOptions(arguments: [String]) {
            #expect(throws: (any Error).self) { try MCPCommandLineOptions(arguments: arguments) }
        }

        @Test
        func rejectsMixedScopesInEitherOrderIncludingAlias() {
            let id = TypeID.encode(.v7(), as: .workspace)
            for flag in ["--workspace", "--workspace-id"] {
                for arguments in [["--account", "local", flag, id], [flag, id, "--account", "local"]] {
                    #expect(throws: MCPAccountScope.Failure.conflictingScopes) {
                        try MCPCommandLineOptions(arguments: arguments)
                    }
                }
            }
        }
    }

    @MainActor
    struct MCPAccountScopeTests {
        @Test
        func scopesLocalServerAndDatabricksAndExposesRegistrationIDs() throws {
            let fixture = try Fixture()
            let serverID = UUID.v7()
            let databricksID = UUID.v7()
            let localWorkspaceID = UUID.v7()
            try fixture.manager.dbQueue.write { db in
                try insertAccount(serverID, kind: "dahlia", in: db)
                try insertAccount(databricksID, kind: "databricks", in: db)
                try db.execute(
                    sql: "UPDATE workspaces SET accountConnectionId = ?, organizationId = ? WHERE id = ?",
                    arguments: [serverID, UUID.v7(), fixture.otherWorkspaceID]
                )
                try db.execute(
                    sql: "UPDATE workspaces SET databricksConnectionId = ? WHERE id = ?",
                    arguments: [databricksID, fixture.primaryWorkspaceID]
                )
                try WorkspaceRecord(id: localWorkspaceID, name: "Local", createdAt: .now, lastOpenedAt: .now).insert(db)
            }
            for (scope, expectedID) in [
                (MCPAccountScope.local, localWorkspaceID), (.account(serverID), fixture.otherWorkspaceID),
                (.account(databricksID), fixture.primaryWorkspaceID),
            ] {
                let server = try DahliaMCPServer(databaseURL: fixture.databaseURL, accountScope: scope)
                let workspaces = try listedWorkspaces(server)
                #expect(workspaces.count == 1)
                #expect((workspaces.first?["id"] as? String)?.lowercased() == expectedID.uuidString.lowercased())
                let grouped = try body(server.executeTool(named: "query_meetings", arguments: [:]))
                let groups = try #require(grouped["workspaces"] as? [[String: Any]])
                #expect(groups.count == 1)
                #expect(groups.first?["workspace_id"] as? String == expectedID.uuidString.lowercased())
            }
            let unscoped = try DahliaMCPServer(databaseURL: fixture.databaseURL)
            _ = unscoped.handleLine(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#)
            _ = unscoped.handleLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
            let line = try #require(unscoped.handleLine(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_workspaces"}}"#))
            let response = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            let result = try body(#require(response["result"] as? [String: Any]))
            let workspaces = try #require(result["workspaces"] as? [[String: Any]])
            #expect(Set(workspaces.compactMap { $0["account_id"] as? String }) == [
                "local",
                serverID.uuidString.lowercased(),
                databricksID.uuidString.lowercased(),
            ])
            #expect(workspaces.allSatisfy { ($0["id"] as? String)?.hasPrefix("ws_") == true })
        }

        @Test
        func rejectsReadsAndWritesOutsideAccountAndPreservesReadOnlyDefault() throws {
            let fixture = try Fixture()
            let accountID = UUID.v7()
            try fixture.manager.dbQueue.write { db in
                try insertAccount(accountID, kind: "databricks", in: db)
                try db.execute(
                    sql: "UPDATE workspaces SET databricksConnectionId = ? WHERE id = ?",
                    arguments: [accountID, fixture.primaryWorkspaceID]
                )
            }
            let server = try DahliaMCPServer(databaseURL: fixture.databaseURL, accountScope: .account(accountID), allowsWrites: true)
            let detail = try server.executeTool(named: "get_meeting", arguments: ["meeting_id": fixture.firstMeetingID.uuidString])
            #expect(detail["isError"] as? Bool == false)
            for tool in ["get_meeting", "get_meeting_transcript", "get_meeting_screenshots"] {
                #expect(throws: MeetingAccessError.workspaceNotFound) {
                    try server.executeTool(named: tool, arguments: ["meeting_id": fixture.otherWorkspaceMeetingID.uuidString])
                }
            }
            #expect(throws: MeetingAccessError.workspaceNotFound) {
                try server.executeTool(named: "get_project", arguments: ["project_id": fixture.otherWorkspaceProjectID.uuidString])
            }
            for tool in ["query_meetings", "query_projects", "query_screenshots"] {
                #expect(throws: MeetingAccessError.workspaceNotFound) {
                    try server.executeTool(named: tool, arguments: ["workspace_id": fixture.otherWorkspaceID.uuidString])
                }
            }
            for arguments: [String: Any] in [
                ["workspace_id": fixture.otherWorkspaceID.uuidString, "name": "Forbidden"],
                ["parent_project_id": fixture.otherWorkspaceProjectID.uuidString, "name": "Forbidden"],
            ] {
                #expect(throws: (any Error).self) { try server.executeTool(named: "create_project", arguments: arguments) }
            }
            #expect(throws: (any Error).self) {
                try server.executeTool(named: "update_meeting_summary", arguments: ["meeting_id": fixture.otherWorkspaceMeetingID.uuidString])
            }
            let arguments = ["workspace_id": fixture.primaryWorkspaceID.uuidString, "name": "Allowed"]
            let readOnly = try DahliaMCPServer(databaseURL: fixture.databaseURL, accountScope: .account(accountID))
            #expect(throws: MeetingAccessError.writeAccessRequired) { try readOnly.executeTool(named: "create_project", arguments: arguments) }
            let created = try server.executeTool(named: "create_project", arguments: arguments)
            #expect(created["isError"] as? Bool == false)
        }

        @Test
        func tracksMembershipChangesAndRejectsUnknownOrRemovedAccounts() throws {
            let fixture = try Fixture()
            let accountID = UUID.v7()
            #expect(throws: MCPAccountScope.Failure.accountNotFound) {
                try DahliaMCPServer(databaseURL: fixture.databaseURL, accountScope: .account(accountID))
            }
            #expect(throws: MCPAccountScope.Failure.conflictingScopes) {
                try DahliaMCPServer(databaseURL: fixture.databaseURL, workspaceID: fixture.primaryWorkspaceID, accountScope: .local)
            }
            try fixture.manager.dbQueue.write { db in try insertAccount(accountID, kind: "databricks", in: db) }
            let server = try DahliaMCPServer(databaseURL: fixture.databaseURL, accountScope: .account(accountID), allowsWrites: true)
            #expect(try listedWorkspaces(server).isEmpty)
            try fixture.manager.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE workspaces SET databricksConnectionId = ? WHERE id = ?",
                    arguments: [accountID, fixture.primaryWorkspaceID]
                )
            }
            #expect(try listedWorkspaces(server).count == 1)
            let scopedStore = server.store.scoped(to: fixture.primaryWorkspaceID)
            #expect(try scopedStore.queryProjects().projects.count == 1)
            try fixture.manager.dbQueue.write { db in
                try db.execute(sql: "UPDATE workspaces SET databricksConnectionId = NULL WHERE id = ?", arguments: [fixture.primaryWorkspaceID])
            }
            #expect(try listedWorkspaces(server).isEmpty)
            #expect(throws: MeetingAccessError.workspaceNotFound) { try scopedStore.meeting(id: fixture.firstMeetingID) }
            #expect(throws: MeetingAccessError.workspaceNotFound) { try scopedStore.queryProjects() }
            #expect(throws: MeetingAccessError.workspaceNotFound) {
                try scopedStore.createProject(name: "Moved", parentProjectID: nil, projectType: nil)
            }
            try fixture.manager.dbQueue.write { db in try db.execute(sql: "DELETE FROM accounts WHERE id = ?", arguments: [accountID]) }
            #expect(throws: MCPAccountScope.Failure.accountNotFound) { try listedWorkspaces(server) }
        }

        private func insertAccount(_ id: UUID, kind: String, in db: Database) throws {
            try DahliaAccountConnectionRecord(
                id: id,
                origin: "https://\(id.uuidString.lowercased()).invalid",
                clientID: "test",
                createdAt: .now,
                kind: kind
            ).insert(db)
        }

        private func body(_ result: [String: Any]) throws -> [String: Any] {
            try #require(result["structuredContent"] as? [String: Any])
        }

        private func listedWorkspaces(_ server: DahliaMCPServer) throws -> [[String: Any]] {
            try #require(body(server.executeTool(named: "list_workspaces", arguments: [:]))["workspaces"] as? [[String: Any]])
        }
    }
#endif
