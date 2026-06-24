// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AuraCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AuraCore", targets: ["AuraCore"]),
    ],
    targets: [
        .target(name: "AuraCore"),
        .testTarget(name: "AuraCoreTests", dependencies: ["AuraCore"]),
    ]
)
