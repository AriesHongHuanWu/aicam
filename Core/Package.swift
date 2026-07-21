// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AICamCore",
    products: [
        .library(name: "AICamCore", targets: ["AICamCore"])
    ],
    targets: [
        .target(name: "AICamCore", path: "Sources/AICamCore"),
        .testTarget(
            name: "AICamCoreTests",
            dependencies: ["AICamCore"],
            path: "Tests/AICamCoreTests"
        )
    ]
)
