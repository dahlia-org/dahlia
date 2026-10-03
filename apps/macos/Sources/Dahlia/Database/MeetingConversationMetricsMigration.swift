import GRDB

enum MeetingConversationMetricsMigration {
    static func migrate(in db: Database) throws {
        guard try db.tableExists(MeetingRecord.databaseTableName) else { return }

        if try !db.tableExists(MeetingConversationMetricsRecord.databaseTableName) {
            try db.create(table: MeetingConversationMetricsRecord.databaseTableName) { table in
                table.primaryKey("meetingId", .blob)
                    .references("meetings", onDelete: .cascade)
                table.column("calculationVersion", .integer).notNull()
                table.column("inputFingerprint", .text).notNull()
                table.column("recordingDuration", .double).notNull()
                table.column("unionSpeechDuration", .double).notNull()
                table.column("overlapDuration", .double).notNull()
                table.column("usesLegacyTimelineFallback", .boolean).notNull()
                table.column("computedAt", .datetime).notNull()
            }
        }

        if try !db.tableExists(MeetingConversationSourceMetricsRecord.databaseTableName) {
            try db.create(table: MeetingConversationSourceMetricsRecord.databaseTableName) { table in
                table.column("meetingId", .blob).notNull()
                    .references(MeetingConversationMetricsRecord.databaseTableName, onDelete: .cascade)
                table.column("source", .text).notNull()
                table.column("speechDuration", .double).notNull()
                table.column("normalizedCharacterCount", .integer).notNull()
                table.column("segmentCount", .integer).notNull()
                table.column("unmeasurableSegmentCount", .integer).notNull()
                table.primaryKey(["meetingId", "source"])
            }
        }
    }
}
