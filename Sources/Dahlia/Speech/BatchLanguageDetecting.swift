import Foundation

enum BatchLanguageDetectorError: Error, Sendable {
    case modelPreparationFailed
    case detectionFailed
}

protocol BatchLanguageDetecting: Sendable {
    func detectLanguage(audioURL: URL) async throws -> String
    func unload() async
}
