import Foundation

actor ApplicationLogSleeperStub {
    private var remainingSuccessfulSleeps: Int

    init(successfulSleepCount: Int) {
        remainingSuccessfulSleeps = successfulSleepCount
    }

    func sleep(for _: Duration) throws {
        guard remainingSuccessfulSleeps > 0 else {
            throw CancellationError()
        }
        remainingSuccessfulSleeps -= 1
    }
}
