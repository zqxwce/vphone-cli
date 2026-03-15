// swift-tools-version:6.0

import PackageDescription

let package = Package(
    name: "Img4tool",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
        .tvOS(.v13),
        .watchOS(.v6),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "Img4tool", targets: ["Img4tool"]),
    ],
    targets: [
        .target(
            name: "Img4tool",
            path: "Sources/Img4tool",
            linkerSettings: [
                .linkedFramework("Security"),
            ]
        ),
        .executableTarget(
            name: "img4cli",
            dependencies: ["Img4tool"],
            path: "Sources/img4cli"
        ),
        .testTarget(
            name: "Img4toolTests",
            dependencies: ["Img4tool"]
        ),
    ]
)
