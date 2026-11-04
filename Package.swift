// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Dabber",
    platforms: [.macOS("26.0"), .iOS("18.0")],
    products: [
        // For the iPad app (iPad/), which is an Xcode project.
        .library(name: "DabberCore", targets: ["DabberCore"]),
        .library(name: "DabberSpeech", targets: ["DabberSpeech"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.5"),
    ],
    targets: [
        .target(name: "DabberCore"),
        .target(name: "DabberSpeech", dependencies: ["DabberCore", .product(name: "FluidAudio", package: "FluidAudio")]),
        .executableTarget(name: "Dabber", dependencies: ["DabberCore", "DabberSpeech"]),
        .testTarget(name: "DabberCoreTests", dependencies: ["DabberCore"]),
        .testTarget(name: "DabberSpeechTests", dependencies: ["DabberSpeech"]),
    ]
)
