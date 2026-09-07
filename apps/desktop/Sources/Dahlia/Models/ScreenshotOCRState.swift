import DahliaRuntimeSupport
import Foundation

enum ScreenshotOCRState: Equatable, Sendable {
    case pending
    case processing
    case completed(ocrText: String, caption: String)
    case failed
    case remote(ocrText: String?, caption: String?, state: TextContentAvailability.State)

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .remote: true
        case .pending, .processing: false
        }
    }
}
