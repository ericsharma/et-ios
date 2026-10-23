// swift-tools-version: 6.0
// The automatic onboarding test of docs/PLAN-macos.md §6. Run it with
// scripts/mac-onboarding-test, which makes the temporary directories.
import PackageDescription

let package = Package(
    name: "MacOnboardingTest",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../../ETCore"),
        .package(path: "../../Vendor/etd/apple/EtLink"),
    ],
    targets: [
        .executableTarget(
            name: "MacOnboardingTest",
            dependencies: [
                .product(name: "ETOnboarding", package: "ETCore"),
                .product(name: "EtLink", package: "EtLink"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
