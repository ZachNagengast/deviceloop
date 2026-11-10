// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "deviceloop",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(
            name: "deviceloop",
            targets: ["deviceloop"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
    ],
    targets: [
        .target(
            name: "DeviceLoopProtocol",
            path: "Runner/Shared",
            swiftSettings: swiftSettings()
        ),
        .target(
            name: "DeviceLoopKit",
            dependencies: [
                "DeviceLoopProtocol",
            ],
            swiftSettings: swiftSettings()
        ),
        .executableTarget(
            name: "deviceloop",
            dependencies: [
                "DeviceLoopKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: swiftSettings()
        ),
        .testTarget(
            name: "DeviceLoopKitTests",
            dependencies: [
                "DeviceLoopKit",
                "deviceloop",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            resources: [
                .copy("Resources"),
            ],
            swiftSettings: swiftSettings()
        ),
    ]
)

func swiftSettings() -> [SwiftSetting] {
    [
        .enableUpcomingFeature("InferIsolatedConformances"),
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    ]
}
