import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    extension PiChatServiceTests {
        @Test(arguments: [false, true])
        func correlatedConfirmationCancellationRemovesOnlyItsOwnCard(afterPublication: Bool) async throws {
            let fixture = try Self.fixture { _ in }
            defer { try? FileManager.default.removeItem(at: fixture.pi.rootURL) }
            let thread = try await fixture.chat.startThread(model: nil, effort: "medium")
            let lease = await fixture.chat.acquireThreadLease(threadID: thread.id)
            let handle = try await fixture.chat.beginTurn(
                threadID: thread.id, inputs: [.text("Question")], model: nil, effort: "medium", approvalMethod: .ask
            )
            let correlation = UUID().uuidString
            await fixture.chatTransport.emit(TestPiTransport.bridgeRequest(id: "first-confirm", method: "confirmation", payload: .object([
                "requestID": .string(correlation), "title": .string("First"), "message": .string("https://example.com/first"),
            ])))
            var events = handle.events.makeAsyncIterator()
            var firstID: String?
            if afterPublication {
                while let event = try await events.next() {
                    if case let .approvalRequested(request) = event { firstID = request.id
                        break
                    }
                }
            }
            let secondCorrelation = UUID().uuidString
            await fixture.chatTransport.emit(TestPiTransport.bridgeRequest(id: "second-confirm", method: "confirmation", payload: .object([
                "requestID": .string(secondCorrelation), "title": .string("Second"), "message": .string("https://example.com/second"),
            ])))
            await fixture.chatTransport.emit(TestPiTransport.bridgeRequest(id: "cancel-first", method: "cancelConfirmation", payload: .object([
                "requestID": .string(correlation),
            ])))
            let acknowledgement = await fixture.chatTransport.command {
                $0["type"] == .string("extension_ui_response") && $0["id"] == .string("cancel-first")
            }
            #expect(acknowledgement["value"] == .string("true"))
            var second: CodexChatApprovalRequest?
            var resolvedFirst = false
            while let event = try await events.next() {
                if case let .approvalRequested(request) = event, request.reason?.hasPrefix("Second") == true { second = request }
                if case let .approvalResolved(id) = event, id == firstID { resolvedFirst = true }
                if second != nil, !afterPublication || resolvedFirst { break }
            }
            let active = try #require(second)
            #expect(await fixture.chat.sessions[thread.id]?.turn?.pendingApprovals.keys.sorted() == [active.id])
            #expect(try fixture.store.thread(id: thread.id, accountID: AppAccount.key).status == "waitingForUser")
            if let firstID {
                await #expect(throws: PiRuntimeError.approvalNoLongerPending) {
                    try await fixture.chat.decideApproval(turnID: handle.id, id: firstID, decision: .accept)
                }
            }
            try await fixture.chat.decideApproval(turnID: handle.id, id: active.id, decision: .accept)
            let accepted = await fixture.chatTransport.command {
                $0["type"] == .string("extension_ui_response") && $0["id"] == .string("second-confirm")
            }
            #expect(accepted["value"] == .string("\"accept\""))
            // A cancellation after the user's decision is harmless.
            await fixture.chatTransport.emit(TestPiTransport.bridgeRequest(id: "cancel-second", method: "cancelConfirmation", payload: .object([
                "requestID": .string(secondCorrelation),
            ])))
            _ = await fixture.chatTransport.command { $0["id"] == .string("cancel-second") }
            #expect(await fixture.chat.sessions[thread.id]?.turn?.pendingApprovals.isEmpty == true)
            await fixture.chatTransport.emit(TestPiTransport.settled())
            while try await events.next() != nil {}
            await fixture.chat.releaseThreadLease(threadID: thread.id, leaseID: lease)
        }

        @Test
        func settlingTurnCancelsAnOutstandingExtensionConfirmation() async throws {
            let fixture = try Self.fixture { _ in }
            defer { try? FileManager.default.removeItem(at: fixture.pi.rootURL) }
            let thread = try await fixture.chat.startThread(model: nil, effort: "medium")
            let lease = await fixture.chat.acquireThreadLease(threadID: thread.id)
            let handle = try await fixture.chat.beginTurn(
                threadID: thread.id, inputs: [.text("Question")], model: nil, effort: "medium", approvalMethod: .ask
            )
            await fixture.chatTransport.emit(.object([
                "type": .string("extension_ui_request"), "id": .string("confirm-disconnect"), "method": .string("confirm"),
                "title": .string("Open page?"), "message": .string("https://example.com/approve"),
            ]))
            var events = handle.events.makeAsyncIterator()
            var requested = false
            while let event = try await events.next() {
                if case .approvalRequested = event { requested = true
                    break
                }
            }
            #expect(requested)
            await fixture.chatTransport.emit(TestPiTransport.settled())
            while try await events.next() != nil {}
            let response = await fixture.chatTransport.command {
                $0["type"] == .string("extension_ui_response") && $0["id"] == .string("confirm-disconnect")
            }
            #expect(response["confirmed"] == .bool(false))
            await fixture.chat.releaseThreadLease(threadID: thread.id, leaseID: lease)
        }

    }
#endif
