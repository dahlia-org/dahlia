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
        case .completed, .failed: true
        case let .remote(_, _, state):
            [.ready, .failed, .deleted, .empty].contains(state)
        case .pending, .processing: false
        }
    }

    func limitingRemoteWait(to elapsed: Duration) -> Self {
        // ponytail: stop after five minutes; use server job status when the API exposes it.
        guard elapsed >= .seconds(300), !isTerminal,
              case let .remote(ocrText, caption, _) = self else { return self }
        return .remote(ocrText: ocrText, caption: caption, state: .failed)
    }
}
