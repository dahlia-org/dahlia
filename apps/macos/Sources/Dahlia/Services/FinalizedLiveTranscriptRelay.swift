import Foundation

actor FinalizedLiveTranscriptRelay {
    struct Delivery: Equatable, Sendable {
        let sessionID: UUID
        let text: String
        let wasTruncated: Bool
    }

    typealias Sink = @MainActor @Sendable (Delivery) async -> Void

    static let maximumPendingCharacters = 100_000

    private let sink: Sink
    private var pendingDelivery: Delivery?
    private var worker: Task<Void, Never>?

    init(sink: @escaping Sink) {
        self.sink = sink
    }

    func enqueue(sessionID: UUID, text: String) {
        guard let text = text.nilIfBlank else { return }
        let combined = pendingDelivery.map { $0.text + "\n" + text } ?? text
        let wasTruncated = pendingDelivery?.wasTruncated == true
            || combined.count > Self.maximumPendingCharacters
        pendingDelivery = Delivery(
            sessionID: sessionID,
            text: String(combined.suffix(Self.maximumPendingCharacters)),
            wasTruncated: wasTruncated
        )
        startWorkerIfNeeded()
    }

    func finish() async {
        await worker?.value
    }

    func cancel() {
        pendingDelivery = nil
        worker?.cancel()
        worker = nil
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while !Task.isCancelled, let delivery = takePendingDelivery() {
            await sink(delivery)
        }
        worker = nil
    }

    private func takePendingDelivery() -> Delivery? {
        defer { pendingDelivery = nil }
        return pendingDelivery
    }
}
