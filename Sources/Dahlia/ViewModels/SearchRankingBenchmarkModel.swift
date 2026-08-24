import Foundation
import GRDB
import Observation
import OSLog

private let benchmarkLogger = Logger(subsystem: "com.dahlia", category: "SearchRankingBenchmark")

/// 実データの正解データでランキング設定を採点し、推奨する重みを提示する。
@MainActor
@Observable
final class SearchRankingBenchmarkModel {
    enum Phase: Equatable {
        case idle
        case generatingJudgments
        case evaluating
    }

    private(set) var phase: Phase = .idle
    private(set) var result: MeetingSearchBenchmarkResult?
    private(set) var errorMessage: String?
    private(set) var judgmentList: MeetingSearchJudgmentList?

    @ObservationIgnored private let database: AppDatabaseManager?
    @ObservationIgnored private var runTask: Task<Void, Never>?

    init(database: AppDatabaseManager?) {
        self.database = database
    }

    var isRunning: Bool { phase != .idle }

    /// 保存済みの正解データを読み込む。保管庫が変わっていれば破棄する。
    func loadStoredJudgments(vaultID: UUID?) {
        guard let vaultID else {
            judgmentList = nil
            return
        }
        let stored = AppSettings.meetingSearchJudgmentList(in: .standard)
        judgmentList = stored?.vaultID == vaultID ? stored : nil
    }

    /// 正解データを作り直してから採点する。
    func regenerateAndRun(vaultID: UUID?) {
        start(vaultID: vaultID, reusingJudgments: false)
    }

    /// 保存済みの正解データがあればそれを使って採点し直す。
    func runWithStoredJudgments(vaultID: UUID?) {
        start(vaultID: vaultID, reusingJudgments: true)
    }

    func cancel() {
        runTask?.cancel()
        runTask = nil
        phase = .idle
    }

    /// 推奨された重みを設定に反映する。
    func applyRecommendation(_ settings: AppSettings = .shared) {
        guard let recommended = result?.recommended.policy else { return }
        settings.meetingSearchRankingPolicy = recommended
        // 反映後の得点は測り直しでしか分からないため、古い結果は残さない。
        result = nil
    }

    private func start(vaultID: UUID?, reusingJudgments: Bool) {
        guard !isRunning else { return }
        guard let database, let vaultID else {
            errorMessage = L10n.searchRequiresVault
            return
        }
        errorMessage = nil
        let reusable = reusingJudgments && judgmentList?.vaultID == vaultID ? judgmentList : nil
        let currentPolicy = AppSettings.shared.meetingSearchRankingPolicy
        let dbQueue = database.dbQueue
        phase = reusable == nil ? .generatingJudgments : .evaluating
        runTask = Task { [weak self] in
            do {
                let judgments: MeetingSearchJudgmentList
                if let reusable, !reusable.isEmpty {
                    judgments = reusable
                } else {
                    judgments = try await MeetingSearchJudgmentService.generateJudgments(
                        vaultID: vaultID,
                        dbQueue: dbQueue
                    )
                    try Task.checkCancellation()
                    guard let self else { return }
                    self.judgmentList = judgments
                    AppSettings.storeMeetingSearchJudgmentList(judgments, in: .standard)
                    self.phase = .evaluating
                }
                let benchmark = try await MeetingSearchRankingBenchmark.run(
                    judgments: judgments.judgments,
                    current: currentPolicy,
                    generatedAt: judgments.generatedAt
                ) { query, policy in
                    try await MeetingRepository.searchMeetingSidebarPage(
                        vaultId: vaultID,
                        query: query,
                        rankingPolicy: policy,
                        limit: MeetingSearchRankingBenchmark.cutoff,
                        dbQueue: dbQueue
                    ).items.map(\.id)
                }
                try Task.checkCancellation()
                guard let self else { return }
                self.result = benchmark
                self.phase = .idle
            } catch is CancellationError {
                self?.phase = .idle
            } catch {
                benchmarkLogger.error(
                    "Search ranking benchmark failed: \(error.localizedDescription, privacy: .public)"
                )
                guard let self else { return }
                self.errorMessage = error.localizedDescription
                self.phase = .idle
            }
        }
    }
}
