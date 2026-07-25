import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct CodexAppServerConcurrencyTests {
        @Test
        func cancellingOneConcurrentGenerationDoesNotInterruptTheOther() async throws {
            let transport = TestCodexAppServerTransport(mode: .generationBlocks)
            let service = CodexAppServerService(transportFactory: { transport })
            let first = Task { try await service.generate(request) }
            let second = Task { try await service.generate(request) }

            try await service.waitUntilActiveTurnCountForTesting(2)
            first.cancel()
            await transport.waitUntilSent("turn/interrupt")

            let messages = await transport.messages()
            let interrupted = try #require(messages.last {
                $0.objectValue?["method"]?.stringValue == "turn/interrupt"
            }?.objectValue?["params"]?.objectValue)
            let interruptedThreadID = try #require(interrupted["threadId"]?.stringValue)
            let interruptedTurnID = try #require(interrupted["turnId"]?.stringValue)
            let remaining = try #require(startedTurns(in: messages).first {
                $0.threadID != interruptedThreadID || $0.turnID != interruptedTurnID
            })
            assertDistinctGenerationContexts(in: messages)

            await completeTurn(remaining, text: #"{"status":"remaining"}"#, transport: transport)

            await #expect(throws: CancellationError.self) { _ = try await first.value }
            #expect(try await second.value == #"{"status":"remaining"}"#)
            let methods = messages.compactMap { $0.objectValue?["method"]?.stringValue }
            #expect(methods.count(where: { $0 == "turn/start" }) == 2)
            #expect(methods.count(where: { $0 == "turn/interrupt" }) == 1)
            await service.shutdown()
        }

        @Test
        func concurrentGenerationsCompleteOutOfOrderIndependently() async throws {
            let transport = TestCodexAppServerTransport(mode: .generationBlocks)
            let service = CodexAppServerService(transportFactory: { transport })
            let first = Task { try await service.generate(request) }
            let second = Task { try await service.generate(request) }

            try await service.waitUntilActiveTurnCountForTesting(2)
            let messages = await transport.messages()
            let turns = startedTurns(in: messages)
            #expect(turns.count == 2)
            assertDistinctGenerationContexts(in: messages)

            await completeTurn(turns[1], text: #"{"order":"second"}"#, transport: transport)
            await completeTurn(turns[0], text: #"{"order":"first"}"#, transport: transport)

            let firstValue = try await first.value
            let secondValue = try await second.value
            let results = [firstValue, secondValue]
            #expect(Set(results) == [#"{"order":"first"}"#, #"{"order":"second"}"#])
            await service.shutdown()
        }

        @Test
        func failedConcurrentGenerationDoesNotInterruptTheOther() async throws {
            let transport = TestCodexAppServerTransport(mode: .generationBlocks)
            let service = CodexAppServerService(transportFactory: { transport })
            let first = Task { try await service.generate(request) }
            let second = Task { try await service.generate(request) }

            try await service.waitUntilActiveTurnCountForTesting(2)
            let turns = await startedTurns(in: transport.messages())
            await failTurn(turns[0], transport: transport)
            await completeTurn(turns[1], text: #"{"status":"survived"}"#, transport: transport)

            let results = await [result(of: first), result(of: second)]
            #expect(results.count(where: {
                guard case let .success(value) = $0 else { return false }
                return value == #"{"status":"survived"}"#
            }) == 1)
            #expect(results.count(where: { result in
                guard case let .failure(error) = result else { return false }
                return error is CodexAppServerError
            }) == 1)
            await service.shutdown()
        }

        @Test
        func timedOutConcurrentGenerationDoesNotInterruptTheOther() async throws {
            let timeout = Duration.seconds(270)
            let clock = SummaryTimeoutTestClock(summaryTimeout: timeout)
            let transport = TestCodexAppServerTransport(mode: .generationBlocks)
            let service = CodexAppServerService(
                transportFactory: { transport },
                clock: clock,
                summaryTimeout: timeout
            )
            let first = Task { try await service.generate(request) }
            let second = Task { try await service.generate(request) }

            try await service.waitUntilActiveTurnCountForTesting(2)
            await clock.waitForSummarySleeps(2)
            await clock.fireNextSummaryTimeout()
            await transport.waitUntilSent("turn/interrupt")

            let messages = await transport.messages()
            let interrupted = try #require(messages.last {
                $0.objectValue?["method"]?.stringValue == "turn/interrupt"
            }?.objectValue?["params"]?.objectValue)
            let remaining = try #require(startedTurns(in: messages).first {
                $0.threadID != interrupted["threadId"]?.stringValue
                    || $0.turnID != interrupted["turnId"]?.stringValue
            })
            await completeTurn(remaining, text: #"{"status":"survived"}"#, transport: transport)

            let results = await [result(of: first), result(of: second)]
            #expect(results.count(where: {
                guard case let .success(value) = $0 else { return false }
                return value == #"{"status":"survived"}"#
            }) == 1)
            #expect(results.count(where: { result in
                guard case let .failure(error) = result,
                      let appServerError = error as? CodexAppServerError,
                      case let .requestTimedOut(operation) = appServerError else { return false }
                return operation == "summary"
            }) == 1)
            await service.shutdown()
        }

        private var request: CodexAppServerRequest {
            CodexAppServerRequest(
                model: nil,
                developerInstructions: "Summarize.",
                inputs: [.text("Transcript")],
                outputSchema: Data(#"{"type":"object"}"#.utf8)
            )
        }

        private func startedTurns(in messages: [JSONValue]) -> [(threadID: String, turnID: String)] {
            messages.enumerated().compactMap { offset, message in
                guard message.objectValue?["method"]?.stringValue == "turn/start",
                      let threadID = message.objectValue?["params"]?.objectValue?["threadId"]?.stringValue else { return nil }
                let index = messages[...offset].count { $0.objectValue?["method"]?.stringValue == "turn/start" }
                return (threadID, "turn-\(index)")
            }
        }

        private func completeTurn(
            _ turn: (threadID: String, turnID: String),
            text: String,
            transport: TestCodexAppServerTransport
        ) async {
            await transport.sendFromServer(.object([
                "method": .string("item/completed"),
                "params": .object([
                    "threadId": .string(turn.threadID),
                    "turnId": .string(turn.turnID),
                    "item": .object([
                        "id": .string("item-remaining"),
                        "type": .string("agentMessage"),
                        "text": .string(text),
                    ]),
                ]),
            ]))
            await transport.sendFromServer(.object([
                "method": .string("turn/completed"),
                "params": .object([
                    "threadId": .string(turn.threadID),
                    "turn": .object([
                        "id": .string(turn.turnID),
                        "status": .string("completed"),
                        "items": .array([]),
                    ]),
                ]),
            ]))
        }

        private func failTurn(
            _ turn: (threadID: String, turnID: String),
            transport: TestCodexAppServerTransport
        ) async {
            await transport.sendFromServer(.object([
                "method": .string("turn/completed"),
                "params": .object([
                    "threadId": .string(turn.threadID),
                    "turn": .object([
                        "id": .string(turn.turnID),
                        "status": .string("failed"),
                        "error": .object(["message": .string("failed")]),
                    ]),
                ]),
            ]))
        }

        private func result(of task: Task<String, any Error>) async -> Result<String, any Error> {
            do {
                return try await .success(task.value)
            } catch {
                return .failure(error)
            }
        }

        private func assertDistinctGenerationContexts(in messages: [JSONValue]) {
            let turns = startedTurns(in: messages)
            #expect(Set(turns.map(\.threadID)).count == 2)
            #expect(Set(turns.map(\.turnID)).count == 2)
            let workingDirectories = messages.compactMap { message -> String? in
                guard message.objectValue?["method"]?.stringValue == "thread/start" else { return nil }
                return message.objectValue?["params"]?.objectValue?["cwd"]?.stringValue
            }
            #expect(Set(workingDirectories).count == 2)
        }
    }

    private actor SummaryTimeoutTestClock: CodexAppServerClock {
        private let summaryTimeout: Duration
        private var summarySleepOrder: [UUID] = []
        private var summarySleepContinuations: [UUID: CheckedContinuation<Void, any Error>] = [:]
        private var sleepWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

        init(summaryTimeout: Duration) {
            self.summaryTimeout = summaryTimeout
        }

        func sleep(for duration: Duration) async throws {
            guard duration == summaryTimeout else {
                try await Task.sleep(for: duration)
                return
            }
            let id = UUID.v7()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    summarySleepOrder.append(id)
                    summarySleepContinuations[id] = continuation
                    resumeSleepWaiters()
                }
            } onCancel: {
                Task { await self.cancelSleep(id) }
            }
        }

        func waitForSummarySleeps(_ count: Int) async {
            if summarySleepContinuations.count >= count { return }
            await withCheckedContinuation { continuation in
                sleepWaiters.append((count, continuation))
            }
        }

        func fireNextSummaryTimeout() {
            guard let id = summarySleepOrder.first else { return }
            summarySleepOrder.removeFirst()
            summarySleepContinuations.removeValue(forKey: id)?.resume()
        }

        private func cancelSleep(_ id: UUID) {
            summarySleepOrder.removeAll { $0 == id }
            summarySleepContinuations.removeValue(forKey: id)?.resume(throwing: CancellationError())
        }

        private func resumeSleepWaiters() {
            let ready = sleepWaiters.filter { summarySleepContinuations.count >= $0.count }
            sleepWaiters.removeAll { summarySleepContinuations.count >= $0.count }
            ready.forEach { $0.continuation.resume() }
        }
    }
#endif
