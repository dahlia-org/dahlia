#if canImport(Testing)
    import Foundation
    import Testing
    @testable import Dahlia

    struct BackupSettingsNavigationTests {
        @Test
        func navigationUsesCurrentVaultWhenSwitchingIsUnavailable() {
            let currentVaultID = UUID.v7()
            let otherVaultID = UUID.v7()
            let items = [
                Self.item(vaultID: otherVaultID),
                Self.item(vaultID: currentVaultID),
            ]

            let target = BackupSettingsView.unprocessedRecordingsTargetVaultID(
                in: items,
                currentVaultID: currentVaultID,
                canSwitchVault: false
            )

            #expect(target == currentVaultID)
        }

        @Test
        func navigationIsUnavailableWhenAnotherVaultCannotBeOpened() {
            let target = BackupSettingsView.unprocessedRecordingsTargetVaultID(
                in: [Self.item(vaultID: .v7())],
                currentVaultID: .v7(),
                canSwitchVault: false
            )

            #expect(target == nil)
        }

        private static func item(vaultID: UUID) -> BackupPreflightItem {
            BackupPreflightItem(
                sessionId: .v7(),
                meetingId: .v7(),
                vaultId: vaultID,
                meetingName: "Recording",
                startedAt: .now,
                state: .failed,
                failureMessage: nil,
                canTranscribe: true
            )
        }
    }
#endif
