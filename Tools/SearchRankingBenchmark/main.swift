import DahliaMeetingAccess
import Foundation
import GRDB

private enum SearchField: String, CaseIterable {
    case title
    case tags
    case calendar
    case description
    case summary
}

private struct SampledMeeting {
    let id: UUID
    let fields: [SearchField: String]

    func contains(_ query: String) -> Bool {
        fields.values.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

private struct Judgment {
    let source: SearchField
    let query: String
    let grades: [UUID: Double]
}

private struct Policy: Hashable, CustomStringConvertible {
    let title: Int
    let tags: Int
    let calendar: Int
    let descriptionWeight: Int
    let summary: Int

    var activeFields: [SearchField] {
        [
            title > 0 ? .title : nil,
            tags > 0 ? .tags : nil,
            calendar > 0 ? .calendar : nil,
            descriptionWeight > 0 ? .description : nil,
            summary > 0 ? .summary : nil,
        ].compactMap(\.self)
    }

    var fieldMask: Int {
        (title > 0 ? 1 : 0)
            | (tags > 0 ? 2 : 0)
            | (calendar > 0 ? 4 : 0)
            | (descriptionWeight > 0 ? 8 : 0)
            | (summary > 0 ? 16 : 0)
    }

    var description: String {
        "title=\(title),tags=\(tags),calendar=\(calendar),description=\(descriptionWeight),summary=\(summary)"
    }
}

private struct Metric {
    let normalizedDiscountedCumulativeGain: Double
    let meanReciprocalRank: Double
    let resultCount: Int
    let exactRank: Int?
}

private struct Evaluation {
    let policy: Policy
    let perQuery: [Metric]
}

enum BenchmarkError: LocalizedError, Equatable {
    case databasePathRequired
    case noMeetings
    case noJudgments
    case searchIndexNotReady(String)
    case searchIndexChanged

    var errorDescription: String? {
        switch self {
        case .databasePathRequired:
            "Usage: swift run dahlia-search-ranking-benchmark /path/to/dahlia.sqlite"
        case .noMeetings:
            "The database has no meetings to benchmark."
        case .noJudgments:
            "The sampled meetings did not contain any usable benchmark queries."
        case let .searchIndexNotReady(phase):
            "The FTS index is not ready (phase: \(phase))."
        case .searchIndexChanged:
            "The FTS index changed while the benchmark was running. Run it again."
        }
    }
}

private let cutoff = 10
private let comparisonThreshold = 0.0001

struct SearchIndexSnapshot: Equatable {
    let phase: String
    let revision: Int

    static func ready(in database: DatabaseQueue) throws -> Self {
        let snapshot = try current(in: database)
        guard snapshot.phase == "ready" else {
            throw BenchmarkError.searchIndexNotReady(snapshot.phase)
        }
        return snapshot
    }

    static func current(in database: DatabaseQueue) throws -> Self {
        try database.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT phase, indexRevision FROM search_index_state WHERE indexKind = 'fts'"
            )
            return Self(
                phase: row?["phase"] ?? "missing",
                revision: row?["indexRevision"] ?? 0
            )
        }
    }
}

/// 本番と同じ検索経路を読み取り専用で全探索し、内容や識別子を含まない集計値だけを出力する。
@main
private enum SearchRankingBenchmarkCommand {
    static func main() throws {
        guard let databasePath = CommandLine.arguments.dropFirst().first else {
            throw BenchmarkError.databasePathRequired
        }

        var configuration = Configuration()
        configuration.readonly = true
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { try SearchFTS5Tokenizer.register(in: $0) }
        let database = try DatabaseQueue(path: databasePath, configuration: configuration)
        let searchIndex = try SearchIndexSnapshot.ready(in: database)
        let dataset = try loadDataset(from: database)
        let policies = makePolicies()
        let startedAt = Date()
        let evaluations = try evaluate(
            policies: policies,
            dataset: dataset,
            database: database
        )
        guard try SearchIndexSnapshot.current(in: database) == searchIndex else {
            throw BenchmarkError.searchIndexChanged
        }
        printReport(
            dataset: dataset,
            evaluations: evaluations,
            elapsed: Date().timeIntervalSince(startedAt),
            searchIndex: searchIndex,
            database: database
        )
    }
}

private struct Dataset {
    let judgments: [Judgment]
    let conjunctions: [[String]]
    let vaultID: UUID
    let sampledMeetingCount: Int
}

private func loadDataset(from database: DatabaseQueue) throws -> Dataset {
    try database.read { db in
        guard let vaultID = try UUID.fetchOne(
            db,
            sql: "SELECT vaultId FROM meetings GROUP BY vaultId ORDER BY COUNT(*) DESC LIMIT 1"
        ) else {
            throw BenchmarkError.noMeetings
        }
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT meetings.id AS id, meetings.name AS name, meetings.description AS description,
                   calendar_events.title AS calendarTitle, calendar_events.description AS calendarDescription
            FROM meetings
            LEFT JOIN calendar_events
              ON calendar_events.ical_uid = meetings.calendar_event_ical_uid
             AND calendar_events.recurrence_id = meetings.calendar_event_recurrence_id
            WHERE meetings.vaultId = ?
            ORDER BY COALESCE(meetings.recordingStartedAt, meetings.createdAt) DESC, meetings.id DESC
            LIMIT 60
            """,
            arguments: [vaultID]
        )
        let samples = try rows.map { row -> SampledMeeting in
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
            let summaryDocument = try String.fetchOne(
                db,
                sql: "SELECT document FROM summaries WHERE meetingId = ?",
                arguments: [id]
            ) ?? ""
            let calendar = [row["calendarTitle"] as String?, row["calendarDescription"] as String?]
                .compactMap(\.self)
                .joined(separator: " ")
            return SampledMeeting(
                id: id,
                fields: [
                    .title: row["name"] ?? "",
                    .tags: tags,
                    .calendar: calendar,
                    .description: row["description"] ?? "",
                    .summary: summaryBody(from: summaryDocument),
                ]
            )
        }
        let judgments = makeJudgments(from: samples)
        guard !judgments.isEmpty else { throw BenchmarkError.noJudgments }
        let conjunctions = try judgments.map { judgment in
            let tokens = try SearchFTS5Tokenizer.queryTokens(for: judgment.query, in: db)
            return tokens.enumerated().map { index, token in
                SearchFTS5Tokenizer.quotedQueryToken(token, isPrefix: index == tokens.count - 1)
            }
        }
        return Dataset(
            judgments: judgments,
            conjunctions: conjunctions,
            vaultID: vaultID,
            sampledMeetingCount: samples.count
        )
    }
}

private func summaryBody(from json: String) -> String {
    guard let data = json.data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let sections = root["sections"] as? [[String: Any]]
    else { return "" }

    var result: [String] = []
    func appendText(_ value: Any?) {
        if let text = value as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(text)
        } else if let object = value as? [String: Any] {
            appendText(object["text"])
        }
    }
    for section in sections {
        appendText(section["heading"])
        for block in section["blocks"] as? [[String: Any]] ?? [] {
            appendText(block["content"])
            for item in block["items"] as? [Any] ?? [] {
                appendText(item)
            }
            for header in block["headers"] as? [Any] ?? [] {
                appendText(header)
            }
            for row in block["rows"] as? [[Any]] ?? [] {
                for cell in row {
                    appendText(cell)
                }
            }
        }
    }
    return result.joined(separator: "\n")
}

private func makeJudgments(from samples: [SampledMeeting]) -> [Judgment] {
    var judgments: [Judgment] = []
    var seenQueries: Set<String> = []
    for sample in samples {
        for field in SearchField.allCases {
            guard let query = queryCandidates(sample.fields[field] ?? "").first(where: {
                seenQueries.insert($0.localizedLowercase).inserted
            }) else { continue }
            var grades: [UUID: Double] = [sample.id: 3]
            for related in samples.lazy.filter({ $0.id != sample.id && $0.contains(query) }).prefix(4) {
                grades[related.id] = 2
            }
            judgments.append(Judgment(source: field, query: query, grades: grades))
            if judgments.count == 20 { return judgments }
        }
    }
    return judgments
}

private func queryCandidates(_ text: String) -> [String] {
    let separators = CharacterSet.whitespacesAndNewlines
        .union(.punctuationCharacters)
        .union(.symbols)
    let parts = text.components(separatedBy: separators).filter {
        $0.count >= 2 && $0.unicodeScalars.contains(where: CharacterSet.letters.contains)
    }
    let normalized = parts.joined(separator: " ")
    var seen: Set<String> = []
    return ([normalized] + parts)
        .map { String($0.prefix(48)) }
        .filter { $0.count >= 2 && seen.insert($0).inserted }
}

private func makePolicies() -> [Policy] {
    let grid = [0, 1, 2, 4, 6, 10]
    var policies: [Policy] = []
    for title in grid {
        for tags in grid {
            for calendar in grid {
                for description in grid {
                    for summary in grid where title + tags + calendar + description + summary > 0 {
                        policies.append(Policy(
                            title: title,
                            tags: tags,
                            calendar: calendar,
                            descriptionWeight: description,
                            summary: summary
                        ))
                    }
                }
            }
        }
    }
    let legacyContentPreset = Policy(
        title: 4,
        tags: 3,
        calendar: 2,
        descriptionWeight: 8,
        summary: 10
    )
    if !policies.contains(legacyContentPreset) { policies.append(legacyContentPreset) }
    return policies
}

private func evaluate(
    policies: [Policy],
    dataset: Dataset,
    database: DatabaseQueue
) throws -> [Evaluation] {
    try database.read { db in
        var statements: [Int: Statement] = [:]
        var evaluations: [Evaluation] = []
        evaluations.reserveCapacity(policies.count)
        for (policyIndex, policy) in policies.enumerated() {
            let statement: Statement
            if let cached = statements[policy.fieldMask] {
                statement = cached
            } else {
                statement = try db.makeStatement(sql: """
                SELECT search_documents.meetingId AS meetingId,
                       -bm25(search_documents_fts, ?, ?, ?, ?, ?, 0, 0, 0) AS relevance,
                       COALESCE(meetings.recordingStartedAt, meetings.createdAt) AS meetingDate
                FROM search_documents_fts
                JOIN search_documents ON search_documents.id = search_documents_fts.rowid
                JOIN meetings ON meetings.id = search_documents.meetingId
                WHERE search_documents_fts MATCH ?
                  AND search_documents.vaultId = ?
                  AND search_documents.kind = 'meeting'
                ORDER BY relevance DESC, meetingDate DESC, meetingId ASC
                LIMIT 10
                """)
                statements[policy.fieldMask] = statement
            }
            var perQuery: [Metric] = []
            perQuery.reserveCapacity(dataset.judgments.count)
            let fields = policy.activeFields.map(\.rawValue).joined(separator: " ")
            for index in dataset.judgments.indices {
                let conjunction = dataset.conjunctions[index].joined(separator: " AND ")
                let expression = "{\(fields)} : (\(conjunction))"
                let ranked = try UUID.fetchAll(
                    statement,
                    arguments: [
                        policy.title,
                        policy.descriptionWeight,
                        policy.summary,
                        policy.calendar,
                        policy.tags,
                        expression,
                        dataset.vaultID,
                    ]
                )
                perQuery.append(metric(ranked: ranked, grades: dataset.judgments[index].grades))
            }
            evaluations.append(Evaluation(policy: policy, perQuery: perQuery))
            if (policyIndex + 1).isMultiple(of: 500) {
                FileHandle.standardError.write(Data("evaluated \(policyIndex + 1)/\(policies.count)\n".utf8))
            }
        }
        return evaluations
    }
}

private func metric(ranked: [UUID], grades: [UUID: Double]) -> Metric {
    let ideal = discountedCumulativeGain(grades.values.sorted(by: >))
    let ndcg = ideal > 0
        ? discountedCumulativeGain(ranked.prefix(cutoff).map { grades[$0] ?? 0 }) / ideal
        : 0
    let relevantRank = ranked.prefix(cutoff).firstIndex { (grades[$0] ?? 0) > 0 }
    let exactID = grades.first { $0.value == 3 }?.key
    return Metric(
        normalizedDiscountedCumulativeGain: ndcg,
        meanReciprocalRank: relevantRank.map { 1 / Double($0 + 1) } ?? 0,
        resultCount: ranked.count,
        exactRank: exactID.flatMap { ranked.firstIndex(of: $0) }.map { $0 + 1 }
    )
}

private func discountedCumulativeGain(_ gains: some Sequence<Double>) -> Double {
    gains.prefix(cutoff).enumerated().reduce(0) { total, entry in
        total + (pow(2, entry.element) - 1) / log2(Double(entry.offset) + 2)
    }
}

private func average(_ metrics: [Metric], indices: [Int]) -> Metric {
    guard !indices.isEmpty else {
        return Metric(
            normalizedDiscountedCumulativeGain: 0,
            meanReciprocalRank: 0,
            resultCount: 0,
            exactRank: nil
        )
    }
    return Metric(
        normalizedDiscountedCumulativeGain: indices.reduce(0) {
            $0 + metrics[$1].normalizedDiscountedCumulativeGain
        } / Double(indices.count),
        meanReciprocalRank: indices.reduce(0) {
            $0 + metrics[$1].meanReciprocalRank
        } / Double(indices.count),
        resultCount: 0,
        exactRank: nil
    )
}

private func isBetter(_ lhs: Metric, than rhs: Metric) -> Bool {
    let ndcgDifference = lhs.normalizedDiscountedCumulativeGain - rhs.normalizedDiscountedCumulativeGain
    if abs(ndcgDifference) > comparisonThreshold { return ndcgDifference > 0 }
    return lhs.meanReciprocalRank > rhs.meanReciprocalRank + comparisonThreshold
}

private func bestEvaluation(
    _ evaluations: [Evaluation],
    indices: [Int],
    requiring predicate: (Policy) -> Bool = { _ in true }
) -> (evaluation: Evaluation, metric: Metric) {
    var selected: (Evaluation, Metric)?
    for evaluation in evaluations where predicate(evaluation.policy) {
        let score = average(evaluation.perQuery, indices: indices)
        if selected == nil || isBetter(score, than: selected!.1) {
            selected = (evaluation, score)
        }
    }
    return selected!
}

private func paired(
    _ lhs: [Metric],
    _ rhs: [Metric],
    indices: [Int]
) -> (wins: Int, ties: Int, losses: Int) {
    var result = (0, 0, 0)
    for index in indices {
        if isBetter(lhs[index], than: rhs[index]) {
            result.0 += 1
        } else if isBetter(rhs[index], than: lhs[index]) {
            result.2 += 1
        } else {
            result.1 += 1
        }
    }
    return result
}

private func printReport(
    dataset: Dataset,
    evaluations: [Evaluation],
    elapsed: TimeInterval,
    searchIndex: SearchIndexSnapshot,
    database: DatabaseQueue
) {
    let all = Array(dataset.judgments.indices)
    let nonTag = all.filter { dataset.judgments[$0].source != .tags }
    let contentOrigin = all.filter {
        [.calendar, .description, .summary].contains(dataset.judgments[$0].source)
    }
    let currentPolicy = Policy(title: 10, tags: 10, calendar: 1, descriptionWeight: 1, summary: 1)
    let currentTagOffPolicy = Policy(title: 10, tags: 0, calendar: 1, descriptionWeight: 1, summary: 1)
    let standardPolicy = Policy(title: 10, tags: 6, calendar: 4, descriptionWeight: 2, summary: 2)
    let standardTagOffPolicy = Policy(title: 10, tags: 0, calendar: 4, descriptionWeight: 2, summary: 2)
    let contentPolicy = Policy(title: 4, tags: 3, calendar: 2, descriptionWeight: 8, summary: 10)
    func evaluation(for policy: Policy) -> Evaluation {
        evaluations.first { $0.policy == policy }!
    }
    let current = evaluation(for: currentPolicy)
    let currentTagOff = evaluation(for: currentTagOffPolicy)
    let standard = evaluation(for: standardPolicy)
    let standardTagOff = evaluation(for: standardTagOffPolicy)
    let content = evaluation(for: contentPolicy)
    let bestAll = bestEvaluation(evaluations, indices: all)
    let bestTagOff = bestEvaluation(evaluations, indices: all) { $0.tags == 0 }
    let bestNonTag = bestEvaluation(evaluations, indices: nonTag)
    let bestContent = bestEvaluation(evaluations, indices: contentOrigin)
    let bestTagOffContent = bestEvaluation(evaluations, indices: contentOrigin) { $0.tags == 0 }

    let fieldCounts = Dictionary(grouping: dataset.judgments, by: \.source).mapValues(\.count)
    let migrationCount = try? database.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations") ?? 0
    }
    print(
        "dataset|sampledMeetings=\(dataset.sampledMeetingCount)|queries=\(dataset.judgments.count)|" +
            "policies=\(evaluations.count)|sourceCounts=" +
            SearchField.allCases.map { "\($0.rawValue):\(fieldCounts[$0, default: 0])" }.joined(separator: ",")
    )
    if let migrationCount {
        print(
            "database|schemaMigrations=\(migrationCount)|ftsIndexRevision=\(searchIndex.revision)|" +
                "ftsPhase=\(searchIndex.phase)"
        )
    }
    print("elapsedSeconds|\(String(format: "%.3f", elapsed))")
    printScore("current_all", current, indices: all)
    printScore("current_tag_off_all", currentTagOff, indices: all)
    printScore("standard_all", standard, indices: all)
    printScore("content_all", content, indices: all)
    printScore("best_all", bestAll.evaluation, indices: all)
    printScore("best_tag_off_all", bestTagOff.evaluation, indices: all)
    printScore("current_non_tag", current, indices: nonTag)
    printScore("current_tag_off_non_tag", currentTagOff, indices: nonTag)
    printScore("standard_non_tag", standard, indices: nonTag)
    printScore("standard_tag_off_non_tag", standardTagOff, indices: nonTag)
    printScore("best_non_tag", bestNonTag.evaluation, indices: nonTag)
    printScore("best_content_origin", bestContent.evaluation, indices: contentOrigin)
    printScore("best_tag_off_content_origin", bestTagOffContent.evaluation, indices: contentOrigin)

    let pairedAll = paired(current.perQuery, currentTagOff.perQuery, indices: all)
    let pairedNonTag = paired(current.perQuery, currentTagOff.perQuery, indices: nonTag)
    print("paired_current_vs_tag_off_all|wins=\(pairedAll.wins)|ties=\(pairedAll.ties)|losses=\(pairedAll.losses)")
    print(
        "paired_current_vs_tag_off_non_tag|wins=\(pairedNonTag.wins)|" +
            "ties=\(pairedNonTag.ties)|losses=\(pairedNonTag.losses)"
    )

    printCrossValidation(dataset: dataset, evaluations: evaluations, all: all)
    printPlateau(evaluations: evaluations, best: bestAll.metric, current: average(current.perQuery, indices: all))
    for field in SearchField.allCases {
        printSourceDiagnostics(
            field: field,
            dataset: dataset,
            current: current,
            currentTagOff: currentTagOff
        )
    }
}

private func printScore(_ label: String, _ evaluation: Evaluation, indices: [Int]) {
    let score = average(evaluation.perQuery, indices: indices)
    print(
        "\(label)|\(evaluation.policy)|" +
            "ndcg=\(String(format: "%.6f", score.normalizedDiscountedCumulativeGain))|" +
            "mrr=\(String(format: "%.6f", score.meanReciprocalRank))|n=\(indices.count)"
    )
}

private func printCrossValidation(
    dataset: Dataset,
    evaluations: [Evaluation],
    all: [Int]
) {
    var folds = Array(repeating: [Int](), count: 4)
    for field in SearchField.allCases {
        for (offset, index) in all.filter({ dataset.judgments[$0].source == field }).enumerated() {
            folds[offset % folds.count].append(index)
        }
    }
    var outOfFold = [Metric?](repeating: nil, count: all.count)
    var selectedPolicies: [Policy] = []
    for test in folds {
        let train = all.filter { !test.contains($0) }
        let selected = bestEvaluation(evaluations, indices: train).evaluation
        selectedPolicies.append(selected.policy)
        for index in test {
            outOfFold[index] = selected.perQuery[index]
        }
    }
    let metrics = outOfFold.compactMap(\.self)
    let score = average(metrics, indices: Array(metrics.indices))
    print(
        "cross_validation|ndcg=\(String(format: "%.6f", score.normalizedDiscountedCumulativeGain))|" +
            "mrr=\(String(format: "%.6f", score.meanReciprocalRank))|foldPolicies=" +
            selectedPolicies.map(\.description).joined(separator: ";")
    )
}

private func printPlateau(
    evaluations: [Evaluation],
    best: Metric,
    current: Metric
) {
    let exactTies = evaluations.filter {
        let score = average($0.perQuery, indices: Array($0.perQuery.indices))
        return abs(score.normalizedDiscountedCumulativeGain - best.normalizedDiscountedCumulativeGain) < 0.000000001
            && abs(score.meanReciprocalRank - best.meanReciprocalRank) < 0.000000001
    }
    let displayTies = evaluations.filter {
        let score = average($0.perQuery, indices: Array($0.perQuery.indices))
        return String(format: "%.3f", score.normalizedDiscountedCumulativeGain)
            == String(format: "%.3f", best.normalizedDiscountedCumulativeGain)
            && String(format: "%.3f", score.meanReciprocalRank)
            == String(format: "%.3f", best.meanReciprocalRank)
    }.count
    print("best_plateau|exactTies=\(exactTies.count)|displayTies=\(displayTies)")

    func values(_ keyPath: KeyPath<Policy, Int>) -> String {
        Array(Set(exactTies.map { $0.policy[keyPath: keyPath] }))
            .sorted()
            .map(String.init)
            .joined(separator: ",")
    }
    print(
        "best_plateau_values|title=\(values(\.title))|tags=\(values(\.tags))|" +
            "calendar=\(values(\.calendar))|description=\(values(\.descriptionWeight))|summary=\(values(\.summary))"
    )
    let strictlyBetter = evaluations.filter {
        isBetter(average($0.perQuery, indices: Array($0.perQuery.indices)), than: current)
    }.count
    print("current_rank|strictlyBetterPolicies=\(strictlyBetter)|totalPolicies=\(evaluations.count)")
}

private func printSourceDiagnostics(
    field: SearchField,
    dataset: Dataset,
    current: Evaluation,
    currentTagOff: Evaluation
) {
    let indices = dataset.judgments.indices.filter { dataset.judgments[$0].source == field }
    guard !indices.isEmpty else { return }
    let currentScore = average(current.perQuery, indices: indices)
    let tagOffScore = average(currentTagOff.perQuery, indices: indices)
    let averageTokens = Double(indices.reduce(0) { $0 + dataset.conjunctions[$1].count }) / Double(indices.count)
    let averageCharacters = Double(indices.reduce(0) { $0 + dataset.judgments[$1].query.count }) / Double(indices.count)
    let nonEmpty = indices.filter { current.perQuery[$0].resultCount > 0 }.count
    let exactTop10 = indices.filter { current.perQuery[$0].exactRank != nil }.count
    print(
        "source|\(field.rawValue)|n=\(indices.count)|" +
            "currentNDCG=\(String(format: "%.6f", currentScore.normalizedDiscountedCumulativeGain))|" +
            "tagOffNDCG=\(String(format: "%.6f", tagOffScore.normalizedDiscountedCumulativeGain))|" +
            "nonEmpty=\(nonEmpty)|exactTop10=\(exactTop10)|avgTokens=\(String(format: "%.2f", averageTokens))|" +
            "avgChars=\(String(format: "%.2f", averageCharacters))"
    )
}
