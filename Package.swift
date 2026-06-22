// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Talking",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Talking", targets: ["Talking"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        // v1.3 Kokoro TTS — Sage-is fork pinned by SHA. The patch on
        // top of FluidInference/FluidAudio exposes
        // `tokenDurationFrames` on `KokoroAneSynthesisResult` for
        // future phoneme-accurate highlights (v1.4); v1.3 only uses
        // the upstream `synthesizeDetailed` API.
        .package(
            url: "https://github.com/Sage-is/FluidAudio.git",
            revision: "692388ace89eedcf6c8abef4419602685ac6ddf2"
        )
    ],
    targets: [
        .executableTarget(
            name: "Talking",
            dependencies: [
                "WhisperKit",
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Talking",
            exclude: ["Talking.entitlements", "Mobile"],
            resources: [
                .copy("Resources/AppIcon.icns")
            ]
        )
    ]
)
