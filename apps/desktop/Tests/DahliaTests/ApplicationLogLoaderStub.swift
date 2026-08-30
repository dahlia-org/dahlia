import Foundation

actor ApplicationLogLoaderStub {
    enum StubError: Error {
        case unavailable
    }

    private var responses: [Result<[String], StubError>]
    private(set) var callCount = 0

    init(responses: [Result<[String], StubError>]) {
        self.responses = responses
    }

    func load() throws -> [String] {
        callCount += 1
        guard !responses.isEmpty else { return [] }
        return try responses.removeFirst().get()
    }
}
