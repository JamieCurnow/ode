// swift-tools-version:6.0
// On-device transcription engines for the bench, kept apart so Ode itself stays dependency-free.
import PackageDescription

let package = Package(
    name: "Bench",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
    ],
    targets: [
        .executableTarget(
            name: "Bench",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/Bench",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
