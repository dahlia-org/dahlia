import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    @Suite(.serialized)
    struct BatchAudioRetentionPeriodTests {
        @Test
        func exposesExpectedPeriodsAndFallsBackToForever() {
            #expect(BatchAudioRetentionPeriod.allCases.map(\.rawValue) == [0, 1, 3, 7, 14])
            #expect(BatchAudioRetentionPeriod.defaultValue == .forever)
            #expect(BatchAudioRetentionPeriod.resolved(rawValue: 999) == .forever)
        }

        @Test
        func ignoresLegacyImmediateDeletionSetting() {
            let retentionSnapshot = UserDefaultsValueSnapshot(key: AppSettings.batchAudioRetentionPeriodUserDefaultsKey)
            let legacySnapshot = UserDefaultsValueSnapshot(key: "retainAudioAfterBatchTranscription")
            defer {
                retentionSnapshot.restore()
                legacySnapshot.restore()
            }
            UserDefaults.standard.removeObject(forKey: AppSettings.batchAudioRetentionPeriodUserDefaultsKey)
            UserDefaults.standard.set(false, forKey: "retainAudioAfterBatchTranscription")

            #expect(AppSettings().batchAudioRetentionPeriod == .forever)
        }

        @Test
        func identifiesOnlyShorterChanges() {
            #expect(BatchAudioRetentionPeriod.oneDay.isShorter(than: .forever))
            #expect(BatchAudioRetentionPeriod.threeDays.isShorter(than: .sevenDays))
            #expect(!BatchAudioRetentionPeriod.forever.isShorter(than: .oneDay))
            #expect(!BatchAudioRetentionPeriod.sevenDays.isShorter(than: .threeDays))
        }
    }

    private struct UserDefaultsValueSnapshot {
        let key: String
        let value: Any?

        init(key: String) {
            self.key = key
            value = UserDefaults.standard.object(forKey: key)
        }

        func restore() {
            if let value {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
#endif
