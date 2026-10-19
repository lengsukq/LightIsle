// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LightIsle",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "LightIsle", targets: ["LightIsle"])],
    targets: [
        .executableTarget(
            name: "LightIsle",
            path: "apps/macos/Sources/LightIsle",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)

