// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Dabber",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "DabberCore"),
        .executableTarget(name: "Dabber", dependencies: ["DabberCore"]),
        .testTarget(name: "DabberCoreTests", dependencies: ["DabberCore"]),
    ]
)
