import FluidAudio
import Foundation

enum SpeakerDiarizationBootstrap {
    static func startProcess() {
        ModelHub.offlineMode = true
    }
}

actor SpeakerDiarizationRuntime {
    private let assetManager: SpeakerModelAssetManager
    private var manager: OfflineDiarizerManager?

    init(assetManager: SpeakerModelAssetManager) {
        self.assetManager = assetManager
    }

    func loadVerifiedModels() async throws {
        let revisionRootURL = try await assetManager.verifiedRevisionRootURL()
        SpeakerDiarizationBootstrap.startProcess()

        let models = try await OfflineDiarizerModels.load(from: revisionRootURL)
        let manager = OfflineDiarizerManager()
        manager.initialize(models: models)
        self.manager = manager
    }
}
