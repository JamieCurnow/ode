// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Ode",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Ode",
            dependencies: ["whisper"],
            path: "Sources/Ode",
            swiftSettings: [.swiftLanguageMode(.v5)],
            // build.sh copies whisper.framework into the app's Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        // whisper.cpp, for on-device transcription (Metal). The build matching release v1.9.5.
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/b5454/whisper-b5454-xcframework.zip",
            checksum: "e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b"
        ),
    ]
)
