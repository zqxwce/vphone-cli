// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "usbaudio-poc",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "usbaudio-poc",
            path: "Sources/usbaudio-poc",
            linkerSettings: [
                .linkedFramework("IOUSBHost"),
                .linkedFramework("IOKit"),
            ]
        ),
        .executableTarget(
            name: "vz-validate",
            path: "Sources/vz-validate",
            linkerSettings: [
                .linkedFramework("Virtualization"),
            ]
        ),
    ]
)
