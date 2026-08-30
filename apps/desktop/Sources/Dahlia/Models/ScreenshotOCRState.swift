import Foundation

enum ScreenshotOCRState: Equatable, Sendable {
    case pending
    case processing
    case completed(ocrText: String, caption: String)
    case failed

    var isTerminal: Bool {
        switch self {
        case .completed, .failed: true
        case .pending, .processing: false
        }
    }
}
