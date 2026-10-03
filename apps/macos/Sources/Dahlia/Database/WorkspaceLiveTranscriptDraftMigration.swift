import Foundation
import GRDB

enum WorkspaceLiveTranscriptDraftMigration {
    static func migrate(in db: Database, defaults: UserDefaults = .standard) throws {
        guard defaults.bool(forKey: "liveTranscriptDraftEnabled") else { return }
        try db.execute(sql: "UPDATE workspaces SET generationSettings = json_set(generationSettings, '$.liveTranscriptDraft', json('true'))")
    }
}
