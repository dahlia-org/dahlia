#if canImport(Testing)
    import DahliaRuntimeSupport
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    struct AgentWorkerDeliveryTests {
        private struct Fixture {
            let inbox: AgentInboxService
            let task: AgentTaskRecord
            let eventID: String
            let account = "local"
            var store: ChatThreadStore { ChatThreadStore(dbQueue: inbox.dbQueue) }
            func queue() throws -> ChatRunRecord {
                try #require(try inbox.queueWorker(
                    taskID: task.id,
                    account: account,
                    input: { _, events in events.map(\.id).joined(separator: ",") }
                ))
            }

            func events() throws -> [AgentEventRecord] {
                try inbox.dbQueue.read { try AgentEventRecord.fetchAll($0, sql: "SELECT * FROM agent_event_inbox ORDER BY createdAt,id") }
            }

            func delivery(_ run: ChatRunRecord) throws -> AgentWorkerDeliveryRecord? {
                try inbox.dbQueue.read { try AgentWorkerDeliveryRecord.fetchOne($0, key: run.id) }
            }
        }

        private func fixture() throws -> Fixture {
            let inbox = try AgentInboxService(dbQueue: AppDatabaseManager(path: ":memory:").dbQueue)
            try inbox.request("Original", account: "local")
            let event = try #require(try inbox.routerInput(account: "local").events.first)
            let task = try inbox.createTask(title: "Work", instructions: "Read", eventIDs: [event.id], caller: .router, account: "local")
            return Fixture(inbox: inbox, task: task, eventID: event.id)
        }

        @Test func queueAndExactBatchCommitTogetherOrNeitherCommits() throws {
            let f = try fixture()
            try f.inbox.dbQueue.write { db in
                try db
                    .execute(
                        sql: "CREATE TRIGGER reject_worker BEFORE INSERT ON agent_worker_deliveries BEGIN SELECT RAISE(ABORT,'test failure'); END"
                    )
            }
            #expect(throws: (any Error).self) { try f.queue() }
            #expect(try f.events().map(\.status) == ["assigned"])
            #expect(try f.inbox.dbQueue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM agent_worker_deliveries") } == 0)
            #expect(try f.store.queuedRuns(accountID: f.account).isEmpty)
            try f.inbox.dbQueue.write { try $0.execute(sql: "DROP TRIGGER reject_worker") }
            let run = try f.queue()
            #expect(run.input == f.eventID)
            #expect(try f.events().first?.deliveryRunID == run.id)
            #expect(try f.delivery(run)?.status == "open")
            #expect(try f.inbox.queueWorker(taskID: f.task.id, account: f.account, input: { _, _ in "duplicate" }) == nil)
        }

        @Test(arguments: ["queued", "running"])
        func closureThenImmediateRecoveryReturnsEveryUnacknowledgedInput(state: String) throws {
            let f = try fixture()
            let run = try f.queue()
            try f.store.setRunStatus(run.id, status: state)
            try f.inbox.request("Follow-up", taskID: f.task.id, account: f.account)
            _ = try f.inbox.route(account: f.account)
            try f.inbox.finishTask(taskID: f.task.id, status: "done", caller: .router, account: f.account)
            // No runtime settlement occurs before this simulated restart.
            try f.inbox.recover()
            #expect(try f.events().map(\.status) == ["unassigned", "unassigned"])
            #expect(try f.events().allSatisfy { $0.taskID == nil && $0.deliveryRunID == nil })
            #expect(try f.delivery(run)?.status == "returned")
            #expect(try !f.inbox.settleWorker(run, account: f.account, succeeded: true, summary: "late"))
            #expect(try f.events().count == 2)
        }

        @Test func reportAcknowledgesItsBatchBeforeClosureOrRuntimeFailure() throws {
            let f = try fixture()
            let run = try f.queue()
            try f.store.setRunStatus(run.id, status: "running")
            let caller = AgentInboxService.Caller.worker(taskID: f.task.id, runID: run.id)
            try f.inbox.addResult(summary: "Done", caller: caller, account: f.account)
            #expect(try f.events().map(\.status) == ["processed", "unassigned"])
            #expect(try f.delivery(run)?.status == "reported")
            #expect(try !f.inbox.settleWorker(run, account: f.account, succeeded: false, summary: "failed after report"))
            try f.inbox.finishTask(taskID: f.task.id, status: "done", caller: .router, account: f.account)
            try f.inbox.recover()
            #expect(try f.events().filter { $0.kind == "result" }.count == 1)
            #expect(try f.events().first?.status == "processed")
        }

        @Test(arguments: [false, true])
        func reportAndClosureBothRevokeAllLateWorkerMutations(closeTask: Bool) throws {
            let f = try fixture()
            let run = try f.queue()
            let caller = AgentInboxService.Caller.worker(taskID: f.task.id, runID: run.id)
            if closeTask {
                try f.inbox.finishTask(taskID: f.task.id, status: "done", caller: .router, account: f.account)
            } else {
                try f.inbox.addResult(summary: "Done", caller: caller, account: f.account)
            }
            #expect(throws: AgentInboxService.Failure.self) {
                try f.inbox.setTimer(note: "Late", dueAt: .now, caller: caller, account: f.account)
            }
            #expect(throws: AgentInboxService.Failure.self) {
                try f.inbox.returnEvents([f.eventID], caller: caller, account: f.account)
            }
            #expect(throws: AgentInboxService.Failure.self) {
                try f.inbox.addResult(summary: "Duplicate", caller: caller, account: f.account)
            }
            #expect(throws: AgentInboxService.Failure.self) {
                try f.inbox.setTimer(note: "Missing run", dueAt: .now, caller: .worker(taskID: f.task.id), account: f.account)
            }
            let count = try f.events().count
            try f.inbox.fireTimers(account: f.account, now: .now.addingTimeInterval(3600))
            #expect(try f.events().count == count)
        }

        @Test func oldRunCannotAcknowledgeTheNextRunsInput() throws {
            let f = try fixture()
            let first = try f.queue()
            let oldCaller = AgentInboxService.Caller.worker(taskID: f.task.id, runID: first.id)
            try f.inbox.addResult(summary: "First", caller: oldCaller, account: f.account)
            try f.store.setRunStatus(first.id, status: "completed")
            try f.inbox.request("Second", taskID: f.task.id, account: f.account)
            _ = try f.inbox.route(account: f.account)
            let next = try f.queue()
            #expect(throws: AgentInboxService.Failure.self) {
                try f.inbox.addResult(summary: "Old callback", caller: oldCaller, account: f.account)
            }
            #expect(try f.events().filter { $0.deliveryRunID == next.id }.map(\.status) == ["delivered"])
            #expect(try !f.inbox.settleWorker(next, account: f.account, succeeded: true, summary: "Fallback"))
            #expect(try f.events().filter { $0.kind == "result" }.count == 2)
            #expect(try f.delivery(next)?.status == "reported")
        }

        @Test func failedUnacknowledgedBatchRetriesAndStaleCapabilityIsRejected() throws {
            let f = try fixture()
            let run = try f.queue()
            try f.store.setRunStatus(run.id, status: "failed")
            #expect(try f.inbox.settleWorker(run, account: f.account, succeeded: false, summary: "Failed"))
            #expect(try f.events().map(\.status) == ["assigned"])
            let retry = try f.queue()
            #expect(retry.input == run.input && retry.id != run.id)
            #expect(throws: AgentInboxService.Failure.self) {
                try f.inbox.setTimer(note: "Old", dueAt: .now, caller: .worker(taskID: f.task.id, runID: run.id), account: f.account)
            }
            #expect(throws: AgentInboxService.Failure.self) {
                try f.inbox.setTimer(note: "Foreign", dueAt: .now, caller: .worker(taskID: f.task.id, runID: retry.id), account: "other")
            }
            try f.store.recoverInterruptedThreads()
            try f.inbox.recover()
            #expect(try f.events().map(\.status) == ["assigned"])
            #expect(try f.delivery(retry)?.status == "retry")
            let afterRestart = try f.queue()
            #expect(afterRestart.id != retry.id && afterRestart.input == run.input)
        }

        @Test(arguments: ["queued", "running"])
        func explicitCancellationIsNeverRetriedAfterRestart(state: String) throws {
            let f = try fixture()
            let run = try f.queue()
            try f.store.setRunStatus(run.id, status: state)
            if state == "queued" { try f.store.interruptQueuedRun(run.id) } else { try f.store.markStoppedByUser(run.id) }
            try f.inbox.recover()
            #expect(try f.delivery(run)?.status == "cancelled")
            #expect(try f.events().map(\.status) == ["processed"])
            #expect(try !f.inbox.settleWorker(run, account: f.account, succeeded: false, summary: "Stopped"))
        }
    }
#endif
