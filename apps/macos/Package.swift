// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HMTrans",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "hmtrans", targets: ["HMTransCLI"]),
        .executable(name: "HMTransMac", targets: ["HMTransMacApp"])
    ],
    targets: [
        .target(
            name: "HMTransCore",
            path: "Sources/HMTransCore"
        ),
        .executableTarget(
            name: "HMTransCLI",
            dependencies: ["HMTransCore"],
            path: "Sources/HMTransMacCLI"
        ),
        .executableTarget(
            name: "HMTransMacApp",
            dependencies: ["HMTransCore"],
            path: "Sources/HMTransMacApp",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("Network"),
                .linkedFramework("QuartzCore")
            ]
        ),
        .testTarget(
            name: "HMTransCoreTests",
            dependencies: ["HMTransCore"],
            path: "Tests/HMTransCoreTests"
        )
    ]
)
