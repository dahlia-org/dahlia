import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CustomerIntelligenceAsyncNavigationTests {
        @Test
        func obsoleteResourceNavigationDoesNotOverrideANewerSectionSelection() async throws {
            let fixture = try CustomerIntelligenceFixture()
            let gate = SuspensionGate()
            let model = CustomerIntelligenceWorkspaceViewModel(
                dbQueue: fixture.manager.dbQueue,
                vaultID: fixture.vault.id,
                scopeContainsLoader: { _, _, _, _, _ in
                    await gate.suspend()
                    return false
                }
            )
            model.scope = .organization(UUID.v7())
            let contactID = UUID.v7()
            let newerSection: CustomerIntelligenceSection = model.section == .topics ? .projects : .topics

            let navigation = Task { await model.openContact(contactID) }
            await gate.waitUntilStarted()
            model.selectSection(newerSection)
            await gate.release()
            await navigation.value

            #expect(model.section == newerSection)
            #expect(model.selection.contactID == nil)
        }

        @Test
        func acceptingAnInsightDoesNotReplaceANewerInsightSelection() async throws {
            let fixture = try CustomerIntelligenceFixture()
            let first = try fixture.repository.createInsight(
                vaultId: fixture.vault.id,
                content: "First"
            )
            let second = try fixture.repository.createInsight(
                vaultId: fixture.vault.id,
                content: "Second"
            )
            let gate = SuspensionGate()
            let model = CustomerIntelligenceInsightsViewModel(
                dbQueue: fixture.manager.dbQueue,
                vaultID: fixture.vault.id,
                scope: .all,
                acceptanceUpdater: { dbQueue, id, vaultID, revision, isAccepted in
                    await gate.suspend()
                    return try MeetingRepository(dbQueue: dbQueue).setInsightAccepted(
                        id: id,
                        vaultId: vaultID,
                        expectedRevision: revision,
                        isAccepted: isAccepted
                    )
                }
            )
            await model.load(selectedID: first.id)

            let acceptance = Task { await model.setAccepted(true) }
            await gate.waitUntilStarted()
            await model.select(second.id)
            await gate.release()
            await acceptance.value

            #expect(model.selectedID == second.id)
            #expect(model.detail?.summary.id == second.id)
            #expect(model.insights.first(where: { $0.id == first.id })?.insight.isAccepted == true)
        }
    }

    private actor SuspensionGate {
        private var isStarted = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseContinuation: CheckedContinuation<Void, Never>?

        func suspend() async {
            isStarted = true
            let waiters = startWaiters
            startWaiters = []
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }

        func waitUntilStarted() async {
            guard !isStarted else { return }
            await withCheckedContinuation { continuation in
                startWaiters.append(continuation)
            }
        }

        func release() {
            releaseContinuation?.resume()
            releaseContinuation = nil
        }
    }
#endif
