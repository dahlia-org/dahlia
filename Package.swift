// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Dahlia",
    defaultLocalization: "ja",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .executable(name: "Dahlia", targets: ["Dahlia"]),
        .executable(name: "dahlia-mcp", targets: ["DahliaMCP"]),
        .executable(name: "dahlia-search-ranking-benchmark", targets: ["DahliaSearchRankingBenchmark"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/getsentry/sentry-cocoa", from: "9.10.0"),
        .package(url: "https://github.com/TelemetryDeck/SwiftSDK", from: "2.13.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.2"),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.0.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.6"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.31.4"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.0"),
    ],
    targets: [
        .binaryTarget(
            name: "DahliaAEC3",
            path: "Vendor/DahliaAEC3.xcframework"
        ),
        .binaryTarget(
            name: "DahliaLindera",
            path: "Vendor/DahliaLindera.xcframework"
        ),
        .target(
            name: "DahliaRuntimeSupport",
            path: "Sources/DahliaRuntimeSupport"
        ),
        .target(
            name: "DahliaMeetingAccess",
            dependencies: [
                "DahliaLindera",
                "DahliaRuntimeSupport",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "GRDBSQLite", package: "GRDB.swift"),
            ],
            path: "Sources/DahliaMeetingAccess"
        ),
        .executableTarget(
            name: "DahliaMCP",
            dependencies: [
                "DahliaMeetingAccess",
                .product(name: "TelemetryDeck", package: "SwiftSDK"),
            ],
            path: "Sources/DahliaMCP"
        ),
        .executableTarget(
            name: "DahliaSearchRankingBenchmark",
            dependencies: [
                "DahliaMeetingAccess",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tools/SearchRankingBenchmark"
        ),
        .executableTarget(
            name: "Dahlia",
            dependencies: [
                "DahliaAEC3",
                "DahliaMeetingAccess",
                "DahliaRuntimeSupport",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Sentry", package: "sentry-cocoa"),
                .product(name: "TelemetryDeck", package: "SwiftSDK"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Hub", package: "swift-transformers"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/Dahlia",
            exclude: [
                "AGENTS.md",
                "CLAUDE.md",
                "Database/AGENTS.md",
                "Database/CLAUDE.md",
            ],
            resources: [.process("Resources"), .copy("CodexSkills")],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("CoreFoundation"),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .testTarget(
            name: "DahliaTests",
            dependencies: [
                "Dahlia",
                "DahliaMeetingAccess",
                "DahliaRuntimeSupport",
                "DahliaSearchRankingBenchmark",
            ],
            path: "Tests/DahliaTests",
            exclude: [
                "AGENTS.md",
                "CLAUDE.md",
            ]
        ),
    ]
)
