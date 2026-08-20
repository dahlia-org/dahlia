import DahliaRuntimeSupport
import Foundation
import GRDB

public enum SummarySearchDatabaseFunction {
    public static let name = "dahlia_summary_body"

    public static func register(in db: Database) {
        db.add(function: DatabaseFunction(name, argumentCount: 1, pure: true) { values in
            bodyText(databaseJSON: String.fromDatabaseValue(values[0]))
        })
    }

    public static func bodyText(databaseJSON: String?) -> String {
        databaseJSON.flatMap { try? SummaryDocument.decode(databaseJSON: $0).searchableBodyText } ?? ""
    }
}
