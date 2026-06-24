// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AuraCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AuraCore", targets: ["AuraCore"]),
        .library(name: "AuraKit", targets: ["AuraKit"]),
    ],
    targets: [
        .target(name: "AuraCore"),
        .testTarget(name: "AuraCoreTests", dependencies: ["AuraCore"]),
        .target(name: "AuraKit", dependencies: ["AuraCore"]),
        .testTarget(name: "AuraKitTests", dependencies: ["AuraKit"]),
    ]
)
