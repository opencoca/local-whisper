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
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0")
    ],
    targets: [
        .executableTarget(
            name: "Talking",
            dependencies: [
                "WhisperKit"
            ],
            path: "Talking",
            exclude: ["Talking.entitlements", "Mobile"],
            resources: [
                .copy("Resources/AppIcon.icns")
            ]
        )
    ]
)
