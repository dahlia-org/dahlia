import GRDB

enum CustomerIntelligenceRemovalMigration {
    static let removedTables = [
        "conversation_topic_references",
        "insight_references",
        "project_resource_references",
        "meeting_participants",
        "organization_memberships",
        "organization_domains",
        "conversation_topics",
        "insights",
        "contacts",
        "organizations",
    ]

    static func migrate(in db: Database) throws {
        if try db.tableExists("calendar_events") {
            try db.alter(table: "calendar_events") {
                $0.add(column: "attendees_json", .text).notNull().defaults(to: "[]")
            }
        }

        for trigger in [
            "projects_cleanup_resource_references",
            "meetings_cleanup_resource_references",
            "projects_cleanup_workspace_references",
            "meetings_cleanup_workspace_references",
        ] {
            try db.execute(sql: "DROP TRIGGER IF EXISTS \(trigger)")
        }

        for table in removedTables {
            try db.execute(sql: "DROP TABLE IF EXISTS \(table)")
        }
    }
}
