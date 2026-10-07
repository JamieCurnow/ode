// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Ode",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Ode",
            path: "Sources/Ode",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
