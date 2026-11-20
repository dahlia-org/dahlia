// swift-tools-version: 6.2
// The on-device transcription helper that Dahlia v2 bundles in Contents/MacOS. No dependencies.
import PackageDescription

let package = Package(
    name: "dahlia-transcribe",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "dahlia-transcribe"),
    ]
)
