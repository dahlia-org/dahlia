#if canImport(Testing)
    import Foundation
    import GRDB
    @testable import Dahlia

    /// Routing fixtures without a running Pi process. Runtime delivery uses queueWorker/report/settleWorker.
    extension AgentInboxService {
        /// The events a task's Worker receives now. They stay delivered until the Worker's run settles.
        func deliver(taskID: String, account: String) throws -> [AgentEventRecord] {
            try dbQueue.write { db in
                let events = try AgentEventRecord.fetchAll(
                    db,
                    sql: "SELECT * FROM agent_event_inbox WHERE accountID=? AND taskID=? AND status='assigned' ORDER BY createdAt, id",
                    arguments: [account, taskID]
                )
                try db.execute(
                    sql: "UPDATE agent_event_inbox SET status='delivered' WHERE accountID=? AND taskID=? AND status='assigned'",
                    arguments: [account, taskID]
                )
                return events
            }
        }

        /// Marks what a Worker's settled run handled. Events of another task stay as they are.
        func markProcessed(_ eventIDs: [String], caller: Caller, account: String) throws {
            guard case let .worker(taskID, _) = caller else { throw Failure(message: "Only a Worker marks its events processed.") }
            try dbQueue.write { db in
                for id in eventIDs {
                    try db.execute(
                        sql: "UPDATE agent_event_inbox SET status='processed' WHERE id=? AND accountID=? AND taskID=? AND status='delivered'",
                        arguments: [id, account, taskID]
                    )
                }
            }
        }

        /// Ends a Worker run's delivery: what it handled is processed, or, when the run failed, waits to be delivered again.
        func settleDelivery(taskID: String, account: String, succeeded: Bool) throws {
            try dbQueue.write {
                try $0.execute(
                    sql: "UPDATE agent_event_inbox SET status=? WHERE accountID=? AND taskID=? AND status='delivered'",
                    arguments: [succeeded ? "processed" : "assigned", account, taskID]
                )
            }
        }
    }
#endif
