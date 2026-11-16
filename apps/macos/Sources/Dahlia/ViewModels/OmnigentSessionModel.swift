import DahliaRuntimeSupport
import Foundation
import Observation

/// One Omnigent session shown in the main area: a snapshot kept current by the session's SSE stream.
/// Everything here is a projection of the server's session; it is rebuilt from a snapshot after every reconnect.
@MainActor
@Observable
final class OmnigentSessionModel {
    let connectionID: UUID
    let sessionID: String
    private(set) var title: String?
    private(set) var status: String?
    private(set) var messages: [OmnigentService.Message] = []
    /// Assistant text streamed since the last finished message.
    private(set) var streamingText = ""
    private(set) var webURL: URL?
    private(set) var isLoaded = false
    private(set) var error: String?
    /// The last chunk index shown per streamed message; the server may resend a chunk.
    private var deltaIndexes: [String: Int] = [:]
    /// Chunks without an index cannot show a gap, so after connecting mid-message they wait for the next message.
    private var acceptsUnindexedDeltas = true

    var isRunning: Bool { ["running", "waiting", "launching"].contains(status ?? "") }

    init(connectionID: UUID, sessionID: String) {
        self.connectionID = connectionID
        self.sessionID = sessionID
    }

    /// Follows the session until the task is cancelled, reconnecting after a dropped stream.
    func follow() async {
        if let connection = try? await DatabricksOAuthService.shared.connection(id: connectionID) {
            webURL = OmnigentService.webURL(host: connection.host, workspaceID: connection.workspaceID, sessionID: sessionID)
        }
        var delay = 1.0
        while !Task.isCancelled {
            var reconciled = false
            var failure: String?
            var connectedAt: ContinuousClock.Instant?
            do {
                for try await event in try await OmnigentService.events(connectionID: connectionID, sessionID: sessionID) {
                    // The first event is the server's heartbeat after subscribing; a snapshot taken now misses nothing.
                    if !reconciled {
                        try await reload()
                        reconciled = true
                        connectedAt = .now
                    }
                    apply(event)
                }
            } catch {
                guard !Task.isCancelled else { return }
                failure = error.localizedDescription
            }
            // A stream that never opened still shows what the session has, and why it does not update.
            if !reconciled { try? await reload() }
            if let failure { error = failure }
            delay = Self.reconnectDelay(after: delay, connectedFor: connectedAt.map { .now - $0 } ?? .zero)
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    /// Backs off from 2 to 60 seconds, starting over only after a connection that stayed up, so a server
    /// that closes the stream at once is not reopened every few seconds.
    nonisolated static func reconnectDelay(after delay: Double, connectedFor: Duration) -> Double {
        connectedFor >= .seconds(60) ? 2 : min(delay * 2, 60)
    }

    func apply(_ event: JSONValue) {
        guard let object = event.objectValue else { return }
        switch object["type"]?.stringValue {
        case "response.output_text.delta":
            // Only the next chunk extends the text: a resent chunk would repeat it, a later one would skip a gap.
            if let id = object["message_id"]?.stringValue, let index = object["index"]?.intValue {
                guard index == deltaIndexes[id, default: -1] + 1 else { return }
                deltaIndexes[id] = index
            } else if !acceptsUnindexedDeltas {
                return
            }
            streamingText += object["delta"]?.stringValue ?? ""
        case "response.output_item.done", "session.input.consumed":
            var item = object["item"]
            if object["type"]?.stringValue == "session.input.consumed" {
                guard let input = object["data"]?.objectValue, var data = input["data"]?.objectValue else { return }
                data["id"] = input["item_id"]
                data["type"] = input["type"]
                item = .object(data)
            }
            guard let message = item.flatMap(OmnigentService.message) else { return }
            if let index = messages.firstIndex(where: { $0.id == message.id }) {
                messages[index] = message
            } else {
                messages.append(message)
            }
            if message.role == "assistant" {
                streamingText = ""
                acceptsUnindexedDeltas = true
            }
        case "session.status":
            // Sub-agent sessions can share the stream; only this session's status is shown.
            guard object["conversation_id"]?.stringValue ?? sessionID == sessionID else { return }
            status = object["status"]?.stringValue ?? status
            if !isRunning {
                streamingText = ""
                acceptsUnindexedDeltas = true
            }
        default:
            break
        }
    }

    private func reload() async throws {
        let snapshot = try await OmnigentService.snapshot(connectionID: connectionID, sessionID: sessionID)
        guard !Task.isCancelled else { return }
        title = snapshot.title
        status = snapshot.status
        messages = snapshot.messages
        // Chunks sent while disconnected are gone; joining the text around the gap would garble it.
        streamingText = ""
        deltaIndexes = [:]
        acceptsUnindexedDeltas = !isRunning
        isLoaded = true
        error = nil
    }
}
