import Foundation

/// Hermes' gateway housekeeping loop: the one clock for unattended upkeep. It wakes every `tick` and runs each chore
/// whose `everyTicks` count has come round. A chore that takes long hands its work to its own task, so the loop never
/// waits on it. Schedules and reviews, the skill Curator, and later mail or Slack checks register here.
actor Housekeeping {
    struct Chore: Sendable {
        let name: String
        let everyTicks: Int
        /// The first tick it runs on; upstream's maintenance timer first polls 90 seconds after start.
        var firstTick = 0
        let run: @Sendable () async -> Void
    }

    static let shared = Housekeeping()
    /// One minute: schedules fire at clock times such as 9:00, and checking is a few SQLite reads.
    static let tick: Duration = .seconds(60)
    private var loop: Task<Void, Never>?

    func start(_ chores: [Chore]) {
        guard loop == nil else { return }
        loop = Task(priority: .utility) {
            var count = 0
            while !Task.isCancelled {
                for chore in chores where Self.isDue(chore, at: count) {
                    await chore.run()
                }
                count += 1
                try? await Task.sleep(for: Self.tick)
            }
        }
    }

    nonisolated static func isDue(_ chore: Chore, at count: Int) -> Bool {
        count >= chore.firstTick && (count - chore.firstTick).isMultiple(of: max(1, chore.everyTicks))
    }
}
