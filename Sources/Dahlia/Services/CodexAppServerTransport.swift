import Foundation

protocol CodexAppServerTransport: Sendable {
    func sendLine(_ data: Data) async throws
    func receiveLine() async throws -> Data?
    func close() async
}
