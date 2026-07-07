import GRDB
@testable import Dahlia

#if canImport(Testing)
import Testing

struct MeetingStatusTests {
    @Test
    func decodesLegacyRecordingStatusAsReady() {
        #expect(MeetingStatus.fromDatabaseValue("RECORDING".databaseValue) == .ready)
    }

    @Test
    func decodesCanonicalStatusesCaseInsensitively() {
        #expect(MeetingStatus.fromDatabaseValue("ready".databaseValue) == .ready)
        #expect(MeetingStatus.fromDatabaseValue("processing_transcript".databaseValue) == .processingTranscript)
        #expect(MeetingStatus.fromDatabaseValue("transcript_not_found".databaseValue) == .transcriptNotFound)
    }
}
#endif
