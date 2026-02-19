// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "DeepCrateMac",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "DeepCrateMac", targets: ["DeepCrateMac"]),
    ],
    targets: [
        .executableTarget(
            name: "DeepCrateMac"
        ),
    ]
)
