// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AuraCore",
    // iOS floor is 26 (see ROH-269). macOS stays at 14 on purpose: the CI
    // `package-tests` job runs `swift test` on a macos-15 runner, which could not
    // execute a macOS 26 binary. The two floors are independent.
    platforms: [.iOS(.v26), .macOS(.v14)],
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
        .target(name: "AuraKit", dependencies: ["AuraCore"],
                resources: [.process("Resources/gems.json"),
                            .process("Resources/golden-ride.gpx"),
                            .process("Resources/golden-ride-paused.gpx")]),
        .testTarget(name: "AuraKitTests", dependencies: ["AuraKit"],
                    resources: [.copy("Resources/terrain-rgb-fixture.png"),
                                .copy("Resources/SairaCondensed-Bold.ttf"),
                                .copy("Resources/SairaCondensed-SemiBold.ttf"),
                                .copy("Resources/sharemap-auraterrain-capture.png")]),
    ],
    swiftLanguageModes: [.v6]
)
