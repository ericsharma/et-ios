// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ETCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "ETCore", targets: ["ETCore"]),
    ],
    targets: [
        .target(name: "ETCore"),
        .testTarget(
            name: "ETCoreTests",
            dependencies: ["ETCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
