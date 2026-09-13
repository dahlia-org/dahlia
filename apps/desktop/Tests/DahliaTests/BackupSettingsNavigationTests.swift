#if canImport(Testing)
    import Foundation
    import Testing
    @testable import Dahlia

    struct BackupSettingsNavigationTests {
        @Test
        func navigationUsesCurrentWorkspaceWhenSwitchingIsUnavailable() {
            let currentWorkspaceID = UUID.v7()
            let otherWorkspaceID = UUID.v7()
            let items = [
                Self.item(workspaceID: otherWorkspaceID),
                Self.item(workspaceID: currentWorkspaceID),
            ]

            let target = BackupSettingsView.unprocessedRecordingsTargetWorkspaceID(
                in: items,
                currentWorkspaceID: currentWorkspaceID,
                canSwitchWorkspace: false
            )

            #expect(target == currentWorkspaceID)
        }

        @Test
        func navigationIsUnavailableWhenAnotherWorkspaceCannotBeOpened() {
            let target = BackupSettingsView.unprocessedRecordingsTargetWorkspaceID(
                in: [Self.item(workspaceID: .v7())],
                currentWorkspaceID: .v7(),
                canSwitchWorkspace: false
            )

            #expect(target == nil)
        }

        private static func item(workspaceID: UUID) -> BackupPreflightItem {
            BackupPreflightItem(
                sessionId: .v7(),
                meetingId: .v7(),
                workspaceId: workspaceID,
                meetingName: "Recording",
                startedAt: .now,
                state: .failed,
                failureMessage: nil,
                canTranscribe: true
            )
        }
    }
#endif
