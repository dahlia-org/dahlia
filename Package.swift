// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Dahlia",
    defaultLocalization: "ja",
    platforms: [
        .macOS(.v26)
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/getsentry/sentry-cocoa", from: "9.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "Dahlia",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Sentry", package: "sentry-cocoa"),
            ],
            path: "Sources/Dahlia",
            exclude: [
                "AGENTS.md",
                "CLAUDE.md",
                "Database/AGENTS.md",
                "Database/CLAUDE.md",
            ],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "DahliaTests",
            dependencies: ["Dahlia"],
            path: "Tests/DahliaTests",
            exclude: [
                "AGENTS.md",
                "CLAUDE.md",
            ]
        )
    ]
)
