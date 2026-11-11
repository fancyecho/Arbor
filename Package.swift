// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Arbor",
    platforms: [.macOS(.v14)],
    targets: [
        // Catches Objective-C exceptions, which Swift can't (see ArborObjC.h).
        .target(name: "ArborObjC", path: "Sources/ArborObjC"),
        .executableTarget(
            name: "Arbor",
            dependencies: ["ArborObjC"],
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
            dependencies: ["Arbor", "ArborObjC"],
            path: "Tests/ArborTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
