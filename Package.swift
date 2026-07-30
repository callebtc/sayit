// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SayIt",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "SayItCore", targets: ["SayItCore"]),
        .library(name: "SayItProtocol", targets: ["SayItProtocol"]),
        .library(name: "SayItBackend", targets: ["SayItBackend"]),
        .library(name: "SayItXPC", targets: ["SayItXPC"]),
        .executable(name: "SayItAgent", targets: ["SayItAgent"]),
        .executable(name: "SayItCLI", targets: ["SayItCLI"]),
        .executable(name: "SayIt", targets: ["SayIt"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/Blaizzy/mlx-audio-swift.git",
            exact: "0.1.3"
        ),
        .package(
            url: "https://github.com/apple/swift-openapi-generator",
            exact: "1.11.1"
        ),
        .package(
            url: "https://github.com/apple/swift-openapi-runtime",
            from: "1.8.2"
        ),
        .package(
            url: "https://github.com/hummingbird-project/hummingbird.git",
            exact: "2.22.0"
        ),
        .package(
            url: "https://github.com/swift-server/swift-openapi-hummingbird",
            exact: "2.0.1"
        ),
        .package(
            url: "https://github.com/apple/swift-argument-parser",
            exact: "1.8.2"
        ),
        .package(
            url: "https://github.com/jpsim/Yams",
            exact: "6.2.2"
        )
    ],
    targets: [
        .target(
            name: "SayItProtocol",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .target(
            name: "SayItCore",
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .target(
            name: "SayItBackend",
            dependencies: [
                "SayItCore",
                "SayItProtocol",
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "MLXAudioTTS", package: "mlx-audio-swift")
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .target(
            name: "SayItXPC",
            dependencies: ["SayItProtocol"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .target(
            name: "SayItHTTP",
            dependencies: [
                "SayItBackend",
                "SayItProtocol",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(
                    name: "OpenAPIHummingbird",
                    package: "swift-openapi-hummingbird"
                ),
                .product(
                    name: "OpenAPIRuntime",
                    package: "swift-openapi-runtime"
                ),
                .product(name: "Yams", package: "Yams")
            ],
            resources: [
                .copy("openapi.yaml")
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ],
            plugins: [
                .plugin(
                    name: "OpenAPIGenerator",
                    package: "swift-openapi-generator"
                )
            ]
        ),
        .executableTarget(
            name: "SayItAgent",
            dependencies: [
                "SayItBackend",
                "SayItCore",
                "SayItHTTP",
                "SayItProtocol",
                "SayItXPC"
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ],
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "SayItCLI",
            dependencies: [
                "SayItProtocol",
                "SayItXPC",
                .product(
                    name: "ArgumentParser",
                    package: "swift-argument-parser"
                )
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "SayIt",
            dependencies: [
                "SayItBackend",
                "SayItCore",
                "SayItProtocol",
                "SayItXPC",
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "MLXAudioTTS", package: "mlx-audio-swift")
            ],
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ],
            linkerSettings: [
                .linkedFramework("Carbon")
            ]
        ),
        .testTarget(
            name: "SayItCoreTests",
            dependencies: ["SayItCore"],
            resources: [
                .process("Fixtures")
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "SayItProtocolTests",
            dependencies: ["SayItProtocol"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "SayItBackendTests",
            dependencies: ["SayItBackend", "SayItProtocol"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "SayItPlaybackTests",
            dependencies: ["SayIt", "SayItBackend"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "SayItHTTPTests",
            dependencies: ["SayItHTTP", "SayItProtocol"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        )
    ]
)
