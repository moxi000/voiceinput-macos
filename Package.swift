// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceInput",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "VoiceInput",
            path: "Sources",
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
            ]
        )
    ]
)
