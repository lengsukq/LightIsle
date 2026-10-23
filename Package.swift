// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LightIsle",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LightIsle", targets: ["LightIsle"]),
        .executable(name: "lightisle-media-worker", targets: ["LightIsleMediaWorker"]),
    ],
    targets: [
        .executableTarget(
            name: "LightIsle",
            path: "apps/macos/Sources/LightIsle",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "LightIsleMediaWorker",
            path: "apps/macos/Sources/LightIsleMediaWorker",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)

