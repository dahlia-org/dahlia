#if canImport(Testing)
import DahliaRuntimeSupport
import Foundation
import Testing
@testable import Dahlia

struct OmnigentServiceTests {
    @Test
    func onlyADatabricksAccountThatTurnedItOnHasAWorkspace() throws {
        let defaults = try #require(UserDefaults(suiteName: "OmnigentServiceTests.\(UUID())"))
        let id = UUID()
        let account = CodexRuntimeProvider.databricks(connectionID: id)
        #expect(OmnigentService.connectionID(for: account, defaults: defaults) == nil)
        defaults.set(true, forKey: OmnigentService.enabledKey(account.accountKey))
        #expect(OmnigentService.connectionID(for: account, defaults: defaults) == id)
        #expect(OmnigentService.connectionID(for: .local, defaults: defaults) == nil)
    }

    @Test
    func startSeparatesManagedCreationFromTaskInput() throws {
        let requests = try OmnigentService.startRequests([
            "agent_id": .string("ag_1"), "input": .string("fix it"), "repository": .string("https://github.com/o/r#main"),
        ])
        let body = requests.session.objectValue
        #expect(body?["host_type"] == .string("managed"))
        #expect(body?["workspace"] == .string("https://github.com/o/r#main"))
        #expect(body?["initial_items"] == .array([]))
        let message = requests.input.objectValue
        #expect(message?["type"] == .string("message"))
        #expect(message?["data"]?.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"] == .string("fix it"))
        #expect(throws: (any Error).self) { try OmnigentService.startRequests(["agent_id": .string("ag_1")]) }
    }

    @Test
    func anUnboundManagedSessionReceivesTheTaskOnceAfterCreation() async throws {
        var paths: [String] = []
        let session = try await OmnigentService.startSession(["agent_id": .string("ag_1"), "input": .string("fix it")]) { path, body in
            paths.append(path)
            if path == "v1/sessions" {
                #expect(body.objectValue?["initial_items"] == .array([]))
                return .object(["id": .string("s1"), "runner_id": .null, "host_id": .null, "status": .string("launching")])
            }
            #expect(path == "v1/sessions/s1/events")
            #expect(body.objectValue?["type"] == .string("message"))
            #expect(body.objectValue?["data"]?.objectValue?["role"] == .string("user"))
            #expect(body.objectValue?["data"]?.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"] == .string("fix it"))
            return .object(["queued": .bool(true), "item_id": .string("m1")])
        }
        #expect(paths == ["v1/sessions", "v1/sessions/s1/events"])
        #expect(session.objectValue?["id"] == .string("s1"))
    }

    @Test(arguments: ["timeout", "denied", "not_queued"])
    func failedTaskSubmissionKeepsTheSessionIdentityAndNeverRetries(failure: String) async throws {
        var paths: [String] = []
        do {
            _ = try await OmnigentService.startSession(["agent_id": .string("ag_1"), "input": .string("fix it")]) { path, _ in
                paths.append(path)
                if path == "v1/sessions" { return .object(["id": .string("s1")]) }
                if failure == "timeout" { throw URLError(.timedOut) }
                return .object(["queued": .bool(failure == "denied"), "denied": .bool(failure == "denied")])
            }
            Issue.record("An unconfirmed task submission must fail")
        } catch {
            #expect(error.localizedDescription.contains("session s1 was created"))
            #expect(error.localizedDescription.contains("do not automatically create another session"))
        }
        #expect(paths == ["v1/sessions", "v1/sessions/s1/events"])
    }

    @Test
    func readKeepsOnlyMessagesOldestFirst() {
        let page = JSONValue.object(["data": .array([
            Self.item("m2", role: "assistant", text: "done"),
            .object(["id": .string("e1"), "type": .string("resource_event")]),
            Self.item("m1", role: "user", text: "go"),
        ])])
        #expect(OmnigentService.messages(page).map(\.text) == ["go", "done"])
    }

    @Test @MainActor
    func streamedTextBecomesTheFinishedMessageOnce() {
        let model = OmnigentSessionModel(connectionID: UUID(), sessionID: "s1")
        model.apply(.object(["type": .string("session.status"), "conversation_id": .string("s1"), "status": .string("running")]))
        model.apply(.object(["type": .string("response.output_text.delta"), "delta": .string("Hel")]))
        model.apply(.object(["type": .string("response.output_text.delta"), "delta": .string("lo")]))
        #expect(model.streamingText == "Hello")
        #expect(model.isRunning)

        let done = JSONValue.object(["type": .string("response.output_item.done"), "item": Self.item("m1", role: "assistant", text: "Hello")])
        model.apply(done)
        model.apply(done)
        #expect(model.messages.map(\.id) == ["m1"])
        #expect(model.streamingText.isEmpty)

        // A sub-agent's status on the same stream leaves this session's alone.
        model.apply(.object(["type": .string("session.status"), "conversation_id": .string("child"), "status": .string("failed")]))
        #expect(model.status == "running")
        model.apply(.object(["type": .string("session.status"), "conversation_id": .string("s1"), "status": .string("idle")]))
        #expect(!model.isRunning)
    }

    @Test @MainActor
    func consumedInputIsShownOnceAlongsideAssistantOutput() throws {
        let model = OmnigentSessionModel(connectionID: UUID(), sessionID: "s1")
        // The snapshot may already contain an input when its queued consumed event arrives.
        let input = Self.item("user1", role: "user", text: "continue")
        model.apply(.object(["type": .string("response.output_item.done"), "item": input]))
        var payload = try #require(input.objectValue)
        payload.removeValue(forKey: "id")
        payload.removeValue(forKey: "type")
        let consumed = JSONValue.object([
            "type": .string("session.input.consumed"),
            "data": .object(["item_id": .string("user1"), "type": .string("message"), "data": .object(payload)]),
        ])
        model.apply(consumed)
        model.apply(consumed)
        #expect(model.messages.map(\.id) == ["user1"])

        payload["content"] = .array([.object(["type": .string("input_text"), "text": .string("next")])])
        let next = JSONValue.object([
            "type": .string("session.input.consumed"),
            "data": .object(["item_id": .string("user2"), "type": .string("message"), "data": .object(payload)]),
        ])
        model.apply(.object(["type": .string("response.output_text.delta"), "delta": .string("working")]))
        model.apply(next)
        model.apply(next)
        #expect(model.streamingText == "working")
        model.apply(.object(["type": .string("response.output_item.done"), "item": Self.item("reply", role: "assistant", text: "done")]))
        #expect(model.messages.map(\.id) == ["user1", "user2", "reply"])
        #expect(model.messages.map(\.text) == ["continue", "next", "done"])
        #expect(model.streamingText.isEmpty)
    }

    @Test @MainActor
    func aResentChunkIsShownOnce() {
        let model = OmnigentSessionModel(connectionID: UUID(), sessionID: "s1")
        for (index, delta) in [(0, "Hel"), (1, "lo"), (1, "lo"), (0, "Hel")] {
            model.apply(.object([
                "type": .string("response.output_text.delta"), "delta": .string(delta),
                "message_id": .string("msg"), "index": .number(Double(index)),
            ]))
        }
        #expect(model.streamingText == "Hello")

        // A message first seen mid-way, as after connecting while it streams, is not shown from its middle.
        model.apply(.object([
            "type": .string("response.output_text.delta"), "delta": .string("tail"),
            "message_id": .string("late"), "index": .number(3),
        ]))
        #expect(model.streamingText == "Hello")
    }

    @Test
    func reconnectingBacksOffUntilAConnectionStaysUp() {
        #expect(OmnigentSessionModel.reconnectDelay(after: 2, connectedFor: .seconds(1)) == 4)
        #expect(OmnigentSessionModel.reconnectDelay(after: 32, connectedFor: .seconds(1)) == 60)
        #expect(OmnigentSessionModel.reconnectDelay(after: 60, connectedFor: .seconds(90)) == 2)
    }

    @Test
    func aSessionShowsOnlyForItsOwnAccount() {
        let connection = UUID()
        let location = MainWindowLocation.omnigentSession(connectionID: connection, sessionID: "s1")
        #expect(location.section == .chat)
        #expect(location.omnigentSessionID(for: connection) == "s1")
        #expect(location.omnigentSessionID(for: UUID()) == nil)
        #expect(location.omnigentSessionID(for: nil) == nil)
        #expect(MainWindowLocation.chat.omnigentSessionID(for: connection) == nil)
    }

    @Test @MainActor
    func theMainAreaLeavesTheSessionWhenAnotherSectionTakesOver() {
        let connection = UUID()
        let navigation = MainWindowNavigation(openMainWindow: {})
        navigation.recordNavigation(to: .omnigentSession(connectionID: connection, sessionID: "s1"))
        #expect(navigation.shownOmnigentSessionID(for: connection) == "s1")
        navigation.showMeetings()
        #expect(navigation.shownOmnigentSessionID(for: connection) == nil)
    }

    private static func item(_ id: String, role: String, text: String) -> JSONValue {
        .object([
            "id": .string(id), "type": .string("message"), "role": .string(role),
            "content": .array([.object(["type": .string("output_text"), "text": .string(text)])]),
        ])
    }

    @Test
    func sessionIDsCannotLeaveTheirPathSegment() {
        #expect(OmnigentService.isValidSessionID("1848829237719641"))
        #expect(OmnigentService.isValidSessionID("conv_abc-1"))
        #expect(!OmnigentService.isValidSessionID("../v1/me"))
        #expect(!OmnigentService.isValidSessionID("a?b"))
        #expect(!OmnigentService.isValidSessionID(""))
    }

    @Test
    func webURLOpensTheWorkspaceUI() {
        let url = OmnigentService.webURL(host: "https://example.cloud.databricks.com", workspaceID: "42", sessionID: "s1")
        #expect(url?.absoluteString == "https://example.cloud.databricks.com/omnigent/c/s1?o=42")
    }
}
#endif
