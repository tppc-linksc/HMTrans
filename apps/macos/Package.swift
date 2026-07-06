// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PureSend",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "puresend", targets: ["PureSendCLI"]),
        .executable(name: "PureSendMac", targets: ["PureSendMacApp"])
    ],
    targets: [
        .target(
            name: "PureSendCore",
            path: "Sources/PureSendCore"
        ),
        .executableTarget(
            name: "PureSendCLI",
            dependencies: ["PureSendCore"],
            path: "Sources/PureSendMacCLI"
        ),
        .executableTarget(
            name: "PureSendMacApp",
            dependencies: ["PureSendCore"],
            path: "Sources/PureSendMacApp",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
