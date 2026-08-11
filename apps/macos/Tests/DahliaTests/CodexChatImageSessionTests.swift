import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CodexChatImageSessionTests {
        @Test
        func failedImageOnlySubmissionRetainsComposerAndRetryClearsAfterSuccess() async throws {
            let service = ImageChatService(supportsImages: true, sendBehavior: .failFirst)
            let session = makeSession(service: service)
            let png = try testPNGData()

            await session.prepare()
            await session.addImageData([png])
            #expect(session.attachedImages.count == 1)
            #expect(session.canSend)

            session.sendDraft()
            await waitUntil { !session.isGenerating }

            #expect(!session.isPreparingTurn)
            #expect(session.attachedImages.count == 1)
            let firstInputs = await service.sentInputs
            #expect(firstInputs.count == 1)
            guard case .imageDataURI = firstInputs[0][0] else {
                Issue.record("Expected an image-only Codex input")
                return
            }
            #expect(await service.threadNames == [L10n.chatImage])

            session.retry()
            await waitUntil { !session.isGenerating }
            #expect(session.attachedImages.isEmpty)
            let retriedInputs = await service.sentInputs
            #expect(retriedInputs.count == 2)
            #expect(retriedInputs[1] == retriedInputs[0])
        }

        @Test
        func composerChangesDuringTurnStartAreNotCleared() async throws {
            let service = ImageChatService(supportsImages: true, sendBehavior: .delayFirst)
            let session = makeSession(service: service)
            let png = try testPNGData()

            await session.prepare()
            session.draft = "Original"
            await session.addImageData([png])
            session.sendDraft()
            await waitUntilAsync { await service.isSendWaiting }

            session.draft = "New draft"
            await session.addImageData([png])
            await service.resumeDelayedSend()
            await waitUntil { !session.isGenerating }

            #expect(session.draft == "New draft")
            #expect(session.attachedImages.count == 2)
        }

        @Test
        func imageSubmissionSteersActiveTurnAndClearsAfterSuccess() async throws {
            let service = ImageChatService(supportsImages: true, sendBehavior: .block)
            let session = makeSession(service: service)
            let png = try testPNGData()

            await session.prepare()
            session.draft = "Start"
            session.sendDraft()
            await waitUntil { session.activeTurnID != nil }

            session.draft = "Follow up"
            await session.addImageData([png])
            session.sendDraft()
            await waitUntilAsync { await service.steeredInputs.count == 1 }

            let steeredInputs = await service.steeredInputs[0]
            #expect(steeredInputs.last?.isImage == true)
            #expect(session.draft.isEmpty)
            #expect(session.attachedImages.isEmpty)
            await service.completeBlockedTurn()
            await waitUntil { !session.isGenerating }
        }

        @Test
        func repeatedSendDoesNotDuplicateManualSubmissionWhileSteering() async throws {
            let service = ImageChatService(supportsImages: true, sendBehavior: .blockSteer)
            let session = makeSession(service: service)
            let png = try testPNGData()

            await session.prepare()
            session.draft = "Start"
            session.sendDraft()
            await waitUntil { session.activeTurnID != nil }

            session.draft = "Follow up"
            await session.addImageData([png])
            session.sendDraft()
            await waitUntilAsync { await service.isSteerWaiting }

            session.sendDraft()
            await service.resumeDelayedSteer()
            await waitUntilAsync { await service.steeredInputs.count == 1 }
            for _ in 0 ..< 10 {
                await Task.yield()
            }

            #expect(await service.steeredInputs.count == 1)
            await service.completeBlockedTurn()
            await waitUntil { !session.isGenerating }
        }

        @Test
        func steerCompletionDoesNotRestoreThinkingAfterOutputStarts() async {
            let service = ImageChatService(supportsImages: true, sendBehavior: .blockSteer)
            let session = makeSession(service: service)

            session.draft = "Start"
            session.sendDraft()
            await waitUntil { session.activeTurnID != nil }

            session.draft = "Follow up"
            session.sendDraft()
            await waitUntilAsync { await service.isSteerWaiting }

            await service.yieldBlockedEvent(.delta(itemID: "response", text: "Output while steering"))
            await waitUntil { session.messages.last?.text == "Output while steering" }
            #expect(!session.showsStandaloneThinking)

            await service.resumeDelayedSteer()
            await waitUntil { session.messages.filter { $0.role == .user }.count == 2 }
            #expect(!session.showsStandaloneThinking)

            await service.completeBlockedTurn()
            await waitUntil { !session.isGenerating }
        }

        @Test
        func staleSteerCompletionDoesNotMutateStoppedSession() async {
            let service = ImageChatService(supportsImages: true, sendBehavior: .blockSteer)
            let session = makeSession(service: service)

            session.draft = "Start"
            session.sendDraft()
            await waitUntil { session.activeTurnID != nil }

            session.draft = "Follow up"
            session.sendDraft()
            await waitUntilAsync { await service.isSteerWaiting }

            session.stop()
            await waitUntil { !session.isGenerating }
            await service.resumeDelayedSteer()
            for _ in 0 ..< 10 {
                await Task.yield()
            }

            #expect(session.messages.filter { $0.role == .user }.map(\.text) == ["Start"])
            #expect(session.draft == "Follow up")
            #expect(!session.showsStandaloneThinking)
        }

        @Test
        func incompatiblePendingImageDoesNotBlockLiveTranscript() async throws {
            let service = ImageChatService(supportsImages: true, sendBehavior: .delayFirstWithoutTurn)
            let session = makeSession(service: service)
            let png = try testPNGData()

            await session.prepare()
            session.toggleLiveMode()
            session.draft = "Start"
            session.sendDraft()
            await waitUntilAsync { await service.isSendWaiting }

            session.draft = "Image pending"
            await session.addImageData([png])
            session.sendDraft()
            session.selectModel("text-only-model")
            session.receiveFinalizedLiveTranscript("Live speech")
            await service.resumeDelayedSend()

            await waitUntilAsync { await service.sentInputs.count == 2 }
            await waitUntil { !session.isGenerating }
            let liveInputs = await service.sentInputs[1]
            #expect(liveInputs.contains { input in
                input.textValue?.contains("Live speech") == true
            })
            #expect(!liveInputs.contains { $0.isImage })

            session.selectModel("default-model")
            await waitUntilAsync { await service.sentInputs.count == 3 }
            await waitUntil { !session.isGenerating }
            #expect(await service.sentInputs[2].contains { $0.isImage })
        }

        @Test
        func meetingReferenceTextPrecedesMultipleImages() async throws {
            let service = ImageChatService(supportsImages: true)
            let session = makeSession(service: service)
            let png = try testPNGData()
            let meetingID = UUID.v7()

            await session.prepare()
            session.addMeetingReference(CodexChatMeetingReference(
                id: meetingID,
                name: "Planning",
                recordingStartedAt: .now
            ))
            session.draft = "Explain these"
            await session.addImageData([png, png])
            session.sendDraft()
            await waitUntil { !session.isGenerating }

            let inputs = await service.sentInputs[0]
            #expect(inputs.count == 3)
            #expect(inputs[0] == .text("meeting:\(meetingID.uuidString.lowercased()) Explain these"))
            #expect(inputs[1].isImage)
            #expect(inputs[2].isImage)
        }

        @Test
        func imageLimitAndTextOnlyModelBlockSending() async throws {
            let service = ImageChatService(supportsImages: false)
            let session = makeSession(service: service)
            let png = try testPNGData()

            await session.addImageData(Array(repeating: png, count: 11))
            #expect(!session.canSend)
            await session.prepare()

            #expect(session.attachedImages.count == 10)
            #expect(!session.canSend)
            #expect(session.attachmentValidationMessage == L10n.chatModelDoesNotSupportImages)
        }

        @Test
        func retryStopsAfterSwitchingToTextOnlyModel() async throws {
            let service = ImageChatService(supportsImages: true, sendBehavior: .failFirst)
            let session = makeSession(service: service)
            let png = try testPNGData()

            await session.prepare()
            await session.addImageData([png])
            session.sendDraft()
            await waitUntil { !session.isGenerating }

            session.selectModel("text-only-model")
            session.retry()
            await Task.yield()

            #expect(await service.sentInputs.count == 1)
            #expect(session.attachedImages.count == 1)
            #expect(session.attachmentValidationMessage == L10n.chatModelDoesNotSupportImages)
        }

        private func makeSession(service: ImageChatService) -> CodexChatSessionModel {
            let settings = AppSettings()
            settings.currentVault = VaultRecord(
                id: .v7(),
                path: "/tmp/chat-image-test-vault",
                name: "Chat Image Test",
                createdAt: .now,
                lastOpenedAt: .now
            )
            return CodexChatSessionModel(
                modelID: "default-model",
                effort: "medium",
                service: service,
                settings: settings
            )
        }

        private func testPNGData() throws -> Data {
            try #require(Data(base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Zl2sAAAAASUVORK5CYII="
            ))
        }

        private func waitUntil(_ predicate: @MainActor () -> Bool) async {
            for _ in 0 ..< 1000 {
                if predicate() { return }
                await Task.yield()
            }
            Issue.record("Timed out waiting for chat image state")
        }

        private func waitUntilAsync(_ predicate: @escaping @Sendable () async -> Bool) async {
            for _ in 0 ..< 1000 {
                if await predicate() { return }
                await Task.yield()
            }
            Issue.record("Timed out waiting for async chat image state")
        }
    }

    private actor ImageChatService: CodexChatServicing {
        enum SendBehavior {
            case complete
            case failFirst
            case delayFirst
            case delayFirstWithoutTurn
            case block
            case blockSteer
        }

        let supportsImages: Bool
        let sendBehavior: SendBehavior
        private(set) var sentInputs: [[CodexAppServerInput]] = []
        private(set) var steeredInputs: [[CodexAppServerInput]] = []
        private(set) var threadNames: [String] = []
        private var delayedSendContinuation: CheckedContinuation<Void, Never>?
        private var delayedSteerContinuation: CheckedContinuation<Void, Never>?
        private var blockedTurnContinuation: AsyncThrowingStream<CodexChatTurnEvent, any Error>.Continuation?

        var isSendWaiting: Bool { delayedSendContinuation != nil }
        var isSteerWaiting: Bool { delayedSteerContinuation != nil }

        init(supportsImages: Bool, sendBehavior: SendBehavior = .complete) {
            self.supportsImages = supportsImages
            self.sendBehavior = sendBehavior
        }

        func models(forceRefresh _: Bool) async throws -> [CodexModel] {
            let selectedModel = CodexModel(
                id: "default",
                model: "default-model",
                displayName: "Default",
                description: "",
                hidden: false,
                isDefault: true,
                supportedReasoningEfforts: [],
                defaultReasoningEffort: "medium",
                inputModalities: supportsImages ? ["text", "image"] : ["text"]
            )
            guard supportsImages else { return [selectedModel] }
            return [
                selectedModel,
                CodexModel(
                    id: "text-only",
                    model: "text-only-model",
                    displayName: "Text only",
                    description: "",
                    hidden: false,
                    isDefault: false,
                    supportedReasoningEfforts: [],
                    defaultReasoningEffort: "medium",
                    inputModalities: ["text"]
                ),
            ]
        }

        func listThreads(cursor _: String?, vaultID _: UUID) async throws -> CodexChatThreadPage {
            CodexChatThreadPage(threads: [], nextCursor: nil)
        }

        func loadThread(id: String) async throws -> CodexChatThread {
            CodexChatThread(id: id, title: L10n.chatImage, messages: [], model: nil, reasoningEffort: nil)
        }

        func resumeThread(id: String, vaultID _: UUID) async throws -> CodexChatThread {
            try await loadThread(id: id)
        }

        func startThread(model _: String?, effort: String, vaultID _: UUID) async throws -> CodexChatThread {
            CodexChatThread(
                id: "thread-image",
                title: "",
                messages: [],
                model: "default-model",
                reasoningEffort: effort
            )
        }

        func setThreadName(threadID _: String, name: String) async {
            threadNames.append(name)
        }

        func send(
            threadID _: String,
            inputs: [CodexAppServerInput],
            model _: String?,
            effort _: String
        ) async throws -> AsyncThrowingStream<CodexChatTurnEvent, any Error> {
            sentInputs.append(inputs)
            if sendBehavior == .failFirst, sentInputs.count == 1 {
                throw CodexAppServerError.invalidProtocolResponse
            }
            if (sendBehavior == .delayFirst || sendBehavior == .delayFirstWithoutTurn), sentInputs.count == 1 {
                await withCheckedContinuation { continuation in
                    delayedSendContinuation = continuation
                }
            }
            let (stream, continuation) = AsyncThrowingStream<CodexChatTurnEvent, any Error>.makeStream()
            if sendBehavior != .delayFirstWithoutTurn || sentInputs.count != 1 {
                continuation.yield(.started(turnID: "turn-image"))
            }
            if sendBehavior == .block || sendBehavior == .blockSteer {
                blockedTurnContinuation = continuation
            } else {
                continuation.yield(.completed(itemID: nil, text: nil))
                continuation.finish()
            }
            return stream
        }

        func respondToApproval(id _: String, decision _: CodexChatApprovalDecision) async {}
        func steer(threadID _: String, turnID _: String, inputs: [CodexAppServerInput]) async throws {
            steeredInputs.append(inputs)
            if sendBehavior == .blockSteer {
                await withCheckedContinuation { continuation in
                    delayedSteerContinuation = continuation
                }
            }
        }
        func interrupt(threadID _: String, turnID _: String) async {}
        func unsubscribe(threadID _: String) async {}

        func resumeDelayedSend() {
            delayedSendContinuation?.resume()
            delayedSendContinuation = nil
        }

        func resumeDelayedSteer() {
            delayedSteerContinuation?.resume()
            delayedSteerContinuation = nil
        }

        func yieldBlockedEvent(_ event: CodexChatTurnEvent) {
            blockedTurnContinuation?.yield(event)
        }

        func completeBlockedTurn() {
            blockedTurnContinuation?.yield(.completed(itemID: nil, text: nil))
            blockedTurnContinuation?.finish()
            blockedTurnContinuation = nil
        }
    }
#endif
