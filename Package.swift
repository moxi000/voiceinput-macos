// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VoiceInput",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "VoiceInput",
            path: "Sources",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
            ]
        )
    ]
)
