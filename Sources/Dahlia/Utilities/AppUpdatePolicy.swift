import DahliaRuntimeSupport
import Foundation

enum AppUpdatePolicy {
    static func shouldStartUpdater(
        runtimeProfile: DahliaRuntimeProfile = DahliaApplicationSupport.profile(),
        feedURL: String? = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
    ) -> Bool {
        guard runtimeProfile == .production, let feedURL else {
            return false
        }

        return !feedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
