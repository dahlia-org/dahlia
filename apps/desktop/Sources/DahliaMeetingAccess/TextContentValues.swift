import Foundation
import GRDB

/// A resident transcript row, returned only by the checked content reader.
public struct TranscriptContent: Decodable, Sendable {
    public var id: UUID
    public var meetingId: UUID
    public var sessionId: UUID?
    public var startTime: Date
    public var endTime: Date?
    public var text: String
    public var translatedText: String?
    public var isConfirmed: Bool
    public var createdAt: Date?
    public var audioSource: String?
    public var speakerLabel: String?
    public var audioFeatureVersion: Int?
    public var audioActiveRmsDecibels: Double?
    public var audioMedianPitchHertz: Double?
    public var audioVoicedFrameRatio: Double?
    public var audioPitchSpreadHertz: Double?

    public init(
        id: UUID,
        meetingId: UUID,
        sessionId: UUID? = nil,
        startTime: Date,
        endTime: Date? = nil,
        text: String,
        translatedText: String? = nil,
        isConfirmed: Bool,
        audioSource: String? = nil,
        speakerLabel: String? = nil,
        audioFeatureVersion: Int? = nil,
        audioActiveRmsDecibels: Double? = nil,
        audioMedianPitchHertz: Double? = nil,
        audioVoicedFrameRatio: Double? = nil,
        audioPitchSpreadHertz: Double? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.meetingId = meetingId
        self.sessionId = sessionId
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.translatedText = translatedText
        self.isConfirmed = isConfirmed
        self.createdAt = createdAt
        self.audioSource = audioSource
        self.speakerLabel = speakerLabel
        self.audioFeatureVersion = audioFeatureVersion
        self.audioActiveRmsDecibels = audioActiveRmsDecibels
        self.audioMedianPitchHertz = audioMedianPitchHertz
        self.audioVoicedFrameRatio = audioVoicedFrameRatio
        self.audioPitchSpreadHertz = audioPitchSpreadHertz
    }

    init(row: Row) throws {
        id = try row.decode(forColumn: "id")
        meetingId = try row.decode(forColumn: "meetingId")
        sessionId = try row.decode(forColumn: "sessionId")
        startTime = try row.decode(forColumn: "startTime")
        endTime = try row.decode(forColumn: "endTime")
        text = try row.decode(forColumn: "text")
        translatedText = try row.decode(forColumn: "translatedText")
        isConfirmed = true
        createdAt = row["createdAt"]
        audioSource = try row.decode(forColumn: "audioSource")
        speakerLabel = try row.decode(forColumn: "speakerLabel")
        audioFeatureVersion = try row.decode(forColumn: "audioFeatureVersion")
        audioActiveRmsDecibels = try row.decode(forColumn: "audioActiveRmsDecibels")
        audioMedianPitchHertz = try row.decode(forColumn: "audioMedianPitchHertz")
        audioVoicedFrameRatio = try row.decode(forColumn: "audioVoicedFrameRatio")
        audioPitchSpreadHertz = try row.decode(forColumn: "audioPitchSpreadHertz")
    }

}

public struct SummaryContent: Decodable, Sendable {
    public var meetingId: UUID
    public var title: String
    public var document: String
    public var createdAt: Date

    public init(meetingId: UUID, title: String, document: String, createdAt: Date) {
        self.meetingId = meetingId
        self.title = title
        self.document = document
        self.createdAt = createdAt
    }

    init(row: Row) throws {
        meetingId = try row.decode(forColumn: "meetingId")
        title = try row.decode(forColumn: "title")
        document = try row.decode(forColumn: "document")
        createdAt = try row.decode(forColumn: "createdAt")
    }

}

public struct FileTextContent: Sendable {
    public var ocrText: String?
    public var caption: String?
}
