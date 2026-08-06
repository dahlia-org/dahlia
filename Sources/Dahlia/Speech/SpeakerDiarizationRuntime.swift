import FluidAudio
import Foundation

enum SpeakerDiarizationBootstrap {
    static func startProcess() {
        ModelHub.offlineMode = true
    }
}

actor SpeakerDiarizationRuntime {
    typealias TestLoader = @Sendable (URL) async throws -> Void

    private let assetManager: SpeakerModelAssetManager
    private let testLoader: TestLoader?
    private var manager: OfflineDiarizerManager?

    init(
        assetManager: SpeakerModelAssetManager,
        testLoader: TestLoader? = nil
    ) {
        self.assetManager = assetManager
        self.testLoader = testLoader
    }

    func loadVerifiedModels() async throws {
        let revisionRootURL = try await assetManager.verifiedRevisionRootURL()
        SpeakerDiarizationBootstrap.startProcess()

        if let testLoader {
            try await testLoader(revisionRootURL)
            return
        }

        let models = try await OfflineDiarizerModels.load(from: revisionRootURL)
        let manager = OfflineDiarizerManager()
        manager.initialize(models: models)
        self.manager = manager
    }
}
