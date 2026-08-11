import Foundation

extension BatchTranscriptionCoordinator: BatchTranscriptionScheduling {
    func notify(meetingId: UUID, state: BatchTranscriptionState) async {
        await onStateChange(BatchTranscriptionUpdate(meetingId: meetingId, state: state))
    }

}
