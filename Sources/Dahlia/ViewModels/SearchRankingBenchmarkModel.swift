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
    /// 実行ごとの世代。取り消し済みの実行が後続の実行の状態を上書きしないようにする。
    @ObservationIgnored private var runGeneration = 0

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
        runGeneration &+= 1
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
        // 探索は数百回の検索を発行するため、書き込みキューを塞がない読み取り専用キューを使う。
        let dbQueue = database.searchDBQueue
        phase = reusable == nil ? .generatingJudgments : .evaluating
        runGeneration &+= 1
        let generation = runGeneration
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
                    guard let self, self.runGeneration == generation else { return }
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
                guard let self, self.runGeneration == generation else { return }
                self.result = benchmark
                self.phase = .idle
            } catch is CancellationError {
                guard let self, self.runGeneration == generation else { return }
                self.phase = .idle
            } catch {
                benchmarkLogger.error(
                    "Search ranking benchmark failed: \(error.localizedDescription, privacy: .public)"
                )
                guard let self, self.runGeneration == generation else { return }
                self.errorMessage = error.localizedDescription
                self.phase = .idle
            }
        }
    }
}
