import GRDB

enum MeetingMetricsMigration {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v31_meetingMetrics") { db in
            try migrate(in: db)
        }
    }

    static func migrate(in db: Database) throws {
        guard try db.tableExists(MeetingRecord.databaseTableName) else { return }
        let meetingColumns = try db.columns(in: MeetingRecord.databaseTableName).map(\.name)
        if !meetingColumns.contains("transcriptRevision") {
            try db.alter(table: MeetingRecord.databaseTableName) {
                $0.add(column: "transcriptRevision", .integer).notNull().defaults(to: 0)
            }
        }

        try db.create(table: "meeting_metrics", options: [.ifNotExists]) { table in
            table.primaryKey("meetingId", .blob).references("meetings", onDelete: .cascade)
            table.column("metricsVersion", .integer).notNull()
            table.column("transcriptRevision", .integer).notNull()
            table.column("conversationTalkSeconds", .double).notNull()
            table.column("overlapSeconds", .double)
            table.column("talkBalance", .double)
            table.column("confirmedSegmentCount", .integer).notNull()
            table.column("validSegmentCount", .integer).notNull()
            table.column("invalidDurationSegmentCount", .integer).notNull()
            table.column("unknownSourceSegmentCount", .integer).notNull()
            table.column("totalCharacterCount", .integer).notNull()
            table.column("validCharacterCount", .integer).notNull()
            table.column("unknownSourceCharacterCount", .integer).notNull()
        }

        try db.create(table: "meeting_source_metrics", options: [.ifNotExists]) { table in
            table.column("meetingId", .blob).notNull().references("meetings", onDelete: .cascade)
            table.column("source", .text).notNull().check { ["mic", "system", "unknown"].contains($0) }
            table.column("speakingSeconds", .double).notNull()
            table.column("characterCount", .integer).notNull()
            table.column("cjkCharacterCount", .integer).notNull()
            table.column("turnCount", .integer).notNull()
            table.column("charactersPerMinute", .double)
            table.primaryKey(["meetingId", "source"])
        }
    }
}
