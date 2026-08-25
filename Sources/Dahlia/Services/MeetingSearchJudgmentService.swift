import Foundation
import GRDB

/// ユーザーの実データから、端末内だけで検索ベンチマークの正解データを作る。
enum MeetingSearchJudgmentService {
    /// 判定に使う meeting 件数の上限。
    static let sampledMeetingLimit = 60
    /// 生成するクエリ数の上限。
    static let requestedQueryCount = 20
    private static let maximumQueryLength = 48

    static func generateJudgments(
        vaultID: UUID,
        dbQueue: DatabaseQueue
    ) async throws -> MeetingSearchJudgmentList {
        let samples = try await sampledMeetings(vaultID: vaultID, dbQueue: dbQueue)
        guard !samples.isEmpty else {
            throw MeetingSearchBenchmarkError.notEnoughMeetings
        }
        let judgments = makeJudgments(from: samples)
        guard !judgments.isEmpty else {
            throw MeetingSearchBenchmarkError.noJudgmentsGenerated
        }
        return MeetingSearchJudgmentList(
            vaultID: vaultID,
            generatedAt: .now,
            sampledMeetingCount: samples.count,
            judgments: judgments
        )
    }

    /// 各 meeting の全検索フィールドから順番にクエリを作り、特定のフィールドだけに偏らせない。
    private static func makeJudgments(from samples: [SampledMeeting]) -> [MeetingSearchJudgment] {
        var seenQueries: Set<String> = []
        var judgments: [MeetingSearchJudgment] = []
        for sample in samples {
            for field in MeetingSearchField.allCases {
                guard let query = queryCandidates(from: sample.text(for: field))
                    .first(where: { seenQueries.insert($0.localizedLowercase).inserted })
                else { continue }
                let related = samples.lazy
                    .filter { $0.id != sample.id && $0.contains(query) }
                    .prefix(4)
                    .map { MeetingSearchJudgment.Entry(meetingID: $0.id, grade: .relevant) }
                judgments.append(MeetingSearchJudgment(
                    query: query,
                    entries: [.init(meetingID: sample.id, grade: .exact)] + related
                ))
                if judgments.count == requestedQueryCount {
                    return judgments
                }
            }
        }
        return judgments
    }

    private static func sampledMeetings(
        vaultID: UUID,
        dbQueue: DatabaseQueue
    ) async throws -> [SampledMeeting] {
        try await dbQueue.read { db in
            let projectPaths = try Dictionary(
                uniqueKeysWithValues: ProjectRecord.fetchResolvedAll(vaultId: vaultID, in: db)
                    .map { ($0.id, $0.path) }
            )
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT meetings.id AS id,
                       meetings.name AS name,
                       meetings.description AS description,
                       meetings.projectId AS projectId,
                       calendar_events.title AS calendarTitle,
                       calendar_events.description AS calendarDescription
                FROM meetings
                LEFT JOIN calendar_events
                  ON calendar_events.ical_uid = meetings.calendar_event_ical_uid
                 AND calendar_events.recurrence_id = meetings.calendar_event_recurrence_id
                WHERE meetings.vaultId = ?
                ORDER BY COALESCE(meetings.recordingStartedAt, meetings.createdAt) DESC, meetings.id DESC
                LIMIT ?
                """,
                arguments: [vaultID, sampledMeetingLimit]
            )
            return try rows.map { row in
                let id: UUID = row["id"]
                let tags = try String.fetchAll(
                    db,
                    sql: """
                    SELECT tags.name FROM tags
                    JOIN meeting_tags ON meeting_tags.tagId = tags.id
                    WHERE meeting_tags.meetingId = ? ORDER BY tags.id
                    """,
                    arguments: [id]
                ).joined(separator: " ")
                let summary = try SummaryRecord.fetchOne(db, key: id)
                    .flatMap { try? $0.loadDocument().searchableBodyText } ?? ""
                let projectID: UUID? = row["projectId"]
                let calendar = [row["calendarTitle"] as String?, row["calendarDescription"] as String?]
                    .compactMap(\.self)
                    .joined(separator: " ")
                return SampledMeeting(
                    id: id,
                    fields: [
                        .title: row["name"] ?? "",
                        .tags: tags,
                        .projectPath: projectID.flatMap { projectPaths[$0] } ?? "",
                        .calendar: calendar,
                        .description: row["description"] ?? "",
                        .summary: summary,
                    ]
                )
            }
        }
    }

    /// 長い本文も検索欄へ入力できる短い候補へ整形する。
    private static func queryCandidates(from text: String) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)
        let parts = text.components(separatedBy: separators)
            .filter { $0.count >= 2 && $0.unicodeScalars.contains(where: CharacterSet.letters.contains) }
        let normalized = parts.joined(separator: " ")
        var seen: Set<String> = []
        return ([normalized] + parts)
            .map { String($0.prefix(maximumQueryLength)) }
            .filter { $0.count >= 2 && seen.insert($0).inserted }
    }

    private struct SampledMeeting: Sendable {
        let id: UUID
        let fields: [MeetingSearchField: String]

        func text(for field: MeetingSearchField) -> String {
            fields[field] ?? ""
        }

        func contains(_ query: String) -> Bool {
            fields.values.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }
}

enum MeetingSearchBenchmarkError: LocalizedError {
    case notEnoughMeetings
    case noJudgmentsGenerated

    var errorDescription: String? {
        switch self {
        case .notEnoughMeetings: L10n.searchBenchmarkNeedsMeetings
        case .noJudgmentsGenerated: L10n.searchBenchmarkNoJudgments
        }
    }
}
