// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DahliaPreviews",
    platforms: [.macOS(.v26)],
    products: [.library(name: "DahliaPreviews", targets: ["DahliaPreviews"])],
    targets: [.target(name: "DahliaPreviews")]
)
