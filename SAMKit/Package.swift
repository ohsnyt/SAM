// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SAMKit",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(name: "SAMKit", targets: ["SAMKit"]),
    ],
    targets: [
        .target(
            name: "SAMKit",
            dependencies: [],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "SAMKitTests",
            dependencies: ["SAMKit"]
        ),
    ]
)
