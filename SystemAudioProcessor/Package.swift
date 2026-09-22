// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SystemAudioProcessor",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SystemAudioProcessor", targets: ["SystemAudioProcessor"]),
        .library(name: "LowEndSupport", targets: ["LowEndSupport"])
    ],
    targets: [
        .target(name: "LowEndSupport"),
        .target(
            name: "AudioRingBufferC",
            path: "Sources/AudioRingBufferC"
        ),
        .target(
            name: "LowEndDSPCoreC",
            dependencies: ["AudioRingBufferC"],
            path: "Sources/LowEndDSPCoreC",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "SystemAudioProcessor",
            dependencies: ["AudioRingBufferC", "LowEndDSPCoreC", "LowEndSupport"],
            resources: [
                .copy("../../Shaders/SpectrumShaders.metal"),
                // Localized app strings (en/ko) are processed into
                // Resources/{en,ko}.lproj inside this target's resource bundle.
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("SceneKit")
            ]
        ),
        .executableTarget(
            name: "LowEndSupportChecks",
            dependencies: ["AudioRingBufferC", "LowEndDSPCoreC", "LowEndSupport"],
            path: "Tests/LowEndSupportChecks"
        ),
        .executableTarget(
            name: "RateMatchBench",
            dependencies: [],
            path: "Tests/RateMatchBench",
            linkerSettings: [
                .linkedFramework("CoreAudio")
            ]
        )
    ],
    cxxLanguageStandard: .cxx17
)
