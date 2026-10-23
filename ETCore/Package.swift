// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ETCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "ETCore", targets: ["ETCore"]),
        .library(name: "ETSSH", targets: ["ETSSH"]),
        .library(name: "ETOnboarding", targets: ["ETOnboarding"]),
    ],
    dependencies: [
        // Vendored with small patches; see Vendor/Citadel/PATCHES.md.
        .package(path: "../Vendor/Citadel"),
    ],
    targets: [
        /// tmux control mode: parser, commands, client. No dependencies, no I/O.
        .target(name: "ETCore"),
        /// SSH transport, keys, host-key pinning, tmux discovery.
        .target(name: "ETSSH", dependencies: [
            "ETCore",
            .product(name: "Citadel", package: "Citadel"),
        ]),
        /// E.T. for macOS: drives the bundled `etd` CLI (docs/PLAN-macos.md §4.2).
        /// Shared by the app and scripts/mac-onboarding-test.
        .target(name: "ETOnboarding"),
        .testTarget(
            name: "ETCoreTests",
            dependencies: ["ETCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
