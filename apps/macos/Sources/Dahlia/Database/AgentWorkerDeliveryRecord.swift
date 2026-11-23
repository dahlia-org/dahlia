import Foundation
import GRDB

/// One exact input batch and its Worker's durable acknowledgement. Reporting closes the run's mutation capability.
struct AgentWorkerDeliveryRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "agent_worker_deliveries"
    var runID: UUID
    var accountID: String
    var taskID: String
    var status: String
    var reportEventID: String?
}
