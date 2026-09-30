import DahliaRuntimeSupport
import Foundation
import GRDB

struct SyncOperationBody: Encodable {
    let id: UUID
    let entity: SyncEntity
    let action: SyncAction
    let entityId: UUID
    let baseRevision: Int?
    let data: JSONValue?

    private enum CodingKeys: String, CodingKey {
        case id
        case entity
        case action
        case entityId
        case baseRevision
        case data
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(entity, forKey: .entity)
        try container.encode(action, forKey: .action)
        try container.encode(entityId, forKey: .entityId)
        if let baseRevision {
            try container.encode(baseRevision, forKey: .baseRevision)
        } else {
            try container.encodeNil(forKey: .baseRevision)
        }
        if let data {
            try container.encode(data, forKey: .data)
        } else {
            try container.encodeNil(forKey: .data)
        }
    }
}

struct SyncTransactionResolution: Decodable {
    let id: UUID
    let status: String
}

struct SyncTransactionBody: Encodable {
    let schemaVersion = 3
    let id: UUID
    let workspaceId: UUID
    let createdAt: Date
    let operations: [SyncOperationBody]
}

struct TranscriptChunkBody: Codable {
    struct Segment: Codable {
        let segmentId: UUID
        let startedAt: Date
        let endedAt: Date?
        let text: String
        let createdAt: Date?
        let audioSource: String?
        let speakerLabel: String?

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(segmentId, forKey: .segmentId)
            try container.encode(startedAt, forKey: .startedAt)
            try container.encode(endedAt, forKey: .endedAt)
            try container.encode(text, forKey: .text)
            try container.encode(createdAt, forKey: .createdAt)
            try container.encode(audioSource, forKey: .audioSource)
            try container.encode(speakerLabel, forKey: .speakerLabel)
        }
    }

    let segments: [Segment]
    let deletions: [UUID]
}

struct TranscriptPatchData: Codable {
    struct Chunk: Codable {
        let index: Int
        let sha256: String
        let segmentCount: Int
        let deletionCount: Int
    }

    let transcript: TranscriptMutation.Descriptor
    let mode: String
    let patchId: UUID
    let segmentCount: Int
    let deletionCount: Int
    let chunks: [Chunk]
}

struct SyncResetSnapshot: Sendable {
    let projects: Set<UUID>
    let meetings: Set<UUID>
    let summaries: Set<UUID>
    let transcripts: Set<UUID>
    let screenshots: Set<UUID>
    let files: Set<UUID>
    let recordings: Set<UUID>

    init(ids: [SyncEntity: Set<UUID>]) {
        projects = ids[.project, default: []]
        meetings = ids[.meeting, default: []]
        summaries = ids[.summary, default: []]
        transcripts = ids[.transcript, default: []]
        screenshots = ids[.meetingAttachment, default: []]
        files = ids[.file, default: []]
        recordings = ids[.recording, default: []]
    }

    init?(_ changes: [SyncChangePage.Change]) {
        guard changes.contains(where: { $0.entity == .workspace && $0.action == "reset" && $0.record != nil }) else {
            return nil
        }
        self.init(canonicalChanges: changes)
    }

    init(canonicalChanges changes: [SyncChangePage.Change]) {
        func ids(_ entity: SyncEntity) -> Set<UUID> {
            Set(changes.lazy.filter { $0.entity == entity && $0.action == "upsert" && $0.record != nil }.map(\.entityId))
        }
        projects = ids(.project)
        meetings = ids(.meeting)
        summaries = ids(.summary)
        transcripts = ids(.transcript)
        screenshots = ids(.meetingAttachment)
        files = ids(.file)
        recordings = ids(.recording)
    }
}

struct SyncProjectSnapshot: Decodable, Sendable {
    var icon: String?
    var color: String?
    let projectId: UUID
    let parentProjectId: UUID?
    let name: String
    let description: String
    let projectType: String?
    let revision: Int
    let createdAt: Date
}

struct SyncProjectSnapshotPage: Decodable {
    let items: [SyncProjectSnapshot]
}

struct SyncMeetingSnapshotHeader: Decodable {
    let meetingId: UUID
    let revision: Int
}

struct SyncTranscriptPage: Decodable {
    struct Segment: Decodable {
        let segmentId: UUID
        let startedAt: Date
        let endedAt: Date?
        let text: String
        let createdAt: Date?
        let audioSource: String?
        let speakerLabel: String?
    }

    let items: [Segment]
    let nextCursor: String?
}

struct SyncTarget: Sendable {
    let workspaceId: UUID
    let connectionId: UUID
    let origin: URL
    let cursor: String?
    let mutationGeneration: Int64
    let lifecycleGeneration: Int64

    var context: RemoteChangePolicy.Context {
        .init(workspaceId: workspaceId, connectionId: connectionId, generation: mutationGeneration, lifecycleGeneration: lifecycleGeneration)
    }

    func matchesMutation(in db: Database) throws -> Bool {
        try SyncTransactionQueue.matchesExpectedConnection(workspaceId: workspaceId, connectionId: connectionId, in: db)
            && Int64.fetchOne(
                db,
                sql: "SELECT syncMutationGeneration FROM workspaces WHERE id = ?",
                arguments: [workspaceId]
            ) == mutationGeneration
    }
}
