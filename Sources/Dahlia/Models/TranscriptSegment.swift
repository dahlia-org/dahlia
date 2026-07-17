import Foundation

enum Formatters {
    /// 録音開始からの経過時間を "00:12:34" 固定幅(HH:mm:ss)で整形する。
    static func elapsedHHmmss(from start: Date, to date: Date) -> String {
        elapsedHHmmss(duration: date.timeIntervalSince(start))
    }

    /// 経過秒数を "00:12:34" 固定幅(HH:mm:ss)で整形する。
    static func elapsedHHmmss(duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    static func elapsedSeconds(
        at date: Date,
        sessionId: UUID?,
        sessions: [RecordingSessionTimeline],
        fallbackTimeBase: Date
    ) -> TimeInterval {
        if let sessionId,
           let session = sessions.first(where: { $0.id == sessionId }) {
            return session.offsetSeconds + date.timeIntervalSince(session.startedAt)
        }

        return date.timeIntervalSince(fallbackTimeBase)
    }

    static func elapsedHHmmss(
        at date: Date,
        sessionId: UUID?,
        sessions: [RecordingSessionTimeline],
        fallbackTimeBase: Date
    ) -> String {
        elapsedHHmmss(
            duration: elapsedSeconds(
                at: date,
                sessionId: sessionId,
                sessions: sessions,
                fallbackTimeBase: fallbackTimeBase
            )
        )
    }
}

extension Sequence<Locale> {
    func sortedByLocalizedName() -> [Locale] {
        sorted {
            ($0.localizedString(forIdentifier: $0.identifier) ?? $0.identifier)
                < ($1.localizedString(forIdentifier: $1.identifier) ?? $1.identifier)
        }
    }
}

/// Speech フレームワークで文字起こしされた1発話区間を表すデータモデル。
struct TranscriptSegment: Identifiable, Equatable {
    let id: UUID
    var sessionId: UUID?
    let startTime: Date
    var endTime: Date?
    var text: String
    var translatedText: String?
    var isConfirmed: Bool
    var speakerLabel: String?

    /// 表示用テキスト。
    var displayText: String { text }

    var displayTranslatedText: String? {
        translatedText?.nilIfBlank
    }

    func visibleTranslatedText(isEnabled: Bool) -> String? {
        guard isEnabled else { return nil }
        return displayTranslatedText
    }

    /// セグメントの長さ（秒）。endTime が未設定なら nil。
    var duration: TimeInterval? {
        guard let end = endTime else { return nil }
        return end.timeIntervalSince(startTime)
    }

    init(
        id: UUID = .v7(),
        sessionId: UUID? = nil,
        startTime: Date,
        endTime: Date? = nil,
        text: String,
        translatedText: String? = nil,
        isConfirmed: Bool = false,
        speakerLabel: String? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.translatedText = translatedText
        self.isConfirmed = isConfirmed
        self.speakerLabel = speakerLabel
    }

    /// TranscriptSegmentRecord からの変換イニシャライザ。
    init(from record: TranscriptSegmentRecord) {
        self.id = record.id
        self.sessionId = record.sessionId
        self.startTime = record.startTime
        self.endTime = record.endTime
        self.text = record.text
        self.translatedText = record.translatedText
        self.isConfirmed = record.isConfirmed
        self.speakerLabel = record.speakerLabel
    }
}
