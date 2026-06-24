// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AuraCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AuraCore", targets: ["AuraCore"]),
        .library(name: "AuraKit", targets: ["AuraKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.17.0"),
    ],
    targets: [
        .target(name: "AuraCore"),
        .testTarget(
            name: "AuraCoreTests",
            dependencies: [
                "AuraCore",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ]
        ),
        .target(name: "AuraKit", dependencies: ["AuraCore"]),
        .testTarget(name: "AuraKitTests", dependencies: ["AuraKit"]),
    ]
)
