import GRDB

enum OrganizationDescriptionMigration {
    static func migrate(in db: Database) throws {
        let columns = try db.columns(in: "organizations")
        guard !columns.contains(where: { $0.name == "description" }) else { return }

        try db.alter(table: "organizations") {
            $0.add(column: "description", .text).notNull().defaults(to: "")
        }
    }
}
