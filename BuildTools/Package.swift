// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BuildTools",
    dependencies: [
        .package(
            url: "https://github.com/nicklockwood/SwiftFormat",
            exact: "0.62.1"
        ),
    ],
    targets: [
        .target(name: "BuildTools", path: ""),
    ]
)
