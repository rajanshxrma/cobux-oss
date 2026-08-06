// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CobuxCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CobuxCore", targets: ["CobuxCore"])
    ],
    targets: [
        .target(name: "CobuxCore"),
        .testTarget(name: "CobuxCoreTests", dependencies: ["CobuxCore"])
    ]
)
