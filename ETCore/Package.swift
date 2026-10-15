// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ETCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "ETCore", targets: ["ETCore"]),
        .library(name: "ETSSH", targets: ["ETSSH"]),
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", exact: "0.12.1"),
    ],
    targets: [
        /// tmux control mode: parser, commands, client. No dependencies, no I/O.
        .target(name: "ETCore"),
        /// SSH transport, keys, host-key pinning, tmux discovery.
        .target(name: "ETSSH", dependencies: [
            "ETCore",
            .product(name: "Citadel", package: "Citadel"),
        ]),
        .testTarget(
            name: "ETCoreTests",
            dependencies: ["ETCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "ETSSHTests", dependencies: ["ETSSH"]),
    ]
)
