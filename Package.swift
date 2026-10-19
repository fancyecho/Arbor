// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Arbor",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Arbor",
            path: "Sources/Arbor",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("Quartz"),
                .linkedFramework("QuickLookThumbnailing"),
                .linkedFramework("Vision"),
                .linkedFramework("NetFS"),
                .linkedFramework("Carbon"),
            ]
        ),
        .testTarget(
            name: "ArborTests",
            dependencies: ["Arbor"],
            path: "Tests/ArborTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
