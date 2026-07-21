// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Dahlia",
    defaultLocalization: "ja",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "Dahlia", targets: ["Dahlia"]),
        .executable(name: "dahlia-mcp", targets: ["DahliaMCP"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/getsentry/sentry-cocoa", from: "9.10.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.2"),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.0.0"),
    ],
    targets: [
        .target(
            name: "DahliaRuntimeSupport",
            path: "Sources/DahliaRuntimeSupport"
        ),
        .target(
            name: "DahliaMeetingAccess",
            dependencies: [
                "DahliaRuntimeSupport",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/DahliaMeetingAccess"
        ),
        .executableTarget(
            name: "DahliaMCP",
            dependencies: ["DahliaMeetingAccess"],
            path: "Sources/DahliaMCP"
        ),
        .executableTarget(
            name: "Dahlia",
            dependencies: [
                "DahliaRuntimeSupport",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Sentry", package: "sentry-cocoa"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            path: "Sources/Dahlia",
            exclude: [
                "AGENTS.md",
                "CLAUDE.md",
                "Database/AGENTS.md",
                "Database/CLAUDE.md",
            ],
            resources: [.process("Resources")],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .testTarget(
            name: "DahliaTests",
            dependencies: ["Dahlia", "DahliaMeetingAccess", "DahliaRuntimeSupport"],
            path: "Tests/DahliaTests",
            exclude: [
                "AGENTS.md",
                "CLAUDE.md",
            ]
        )
    ]
)
