// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PlaybackDSP",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PlaybackDSP", targets: ["PlaybackDSP"]),
        .executable(name: "PlaybackDSPRender", targets: ["PlaybackDSPRender"])
    ],
    targets: [
        .target(
            name: "CPlaybackDSP",
            exclude: ["vendor/LICENSE"],
            sources: ["TimeStretch.cpp", "vendor/sonic.c"],
            publicHeadersPath: "include",
            cxxSettings: [.headerSearchPath("vendor")]
        ),
        .target(name: "PlaybackDSP", dependencies: ["CPlaybackDSP"]),
        .testTarget(name: "PlaybackDSPTests", dependencies: ["PlaybackDSP"]),
        .executableTarget(name: "PlaybackDSPRender", dependencies: ["PlaybackDSP"])
    ],
    cxxLanguageStandard: .cxx17
)
