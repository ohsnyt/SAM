// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SummaryBench",
    platforms: [
        .macOS("26.0"),
    ],
    products: [
        .executable(name: "summary-bench", targets: ["SummaryBench"]),
    ],
    targets: [
        .executableTarget(
            name: "SummaryBench",
            path: "Sources/SummaryBench"
        ),
    ]
)
