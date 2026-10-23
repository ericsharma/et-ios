// swift-tools-version:6.0
// SwiftTerm 1.20.0, vendored: the library target only, without its build
// tool plugin (see PATCHES.md).
import PackageDescription

let package = Package(
    name: "SwiftTerm",
    platforms: [.iOS(.v14), .macOS(.v11)],
    products: [.library(name: "SwiftTerm", targets: ["SwiftTerm"])],
    targets: [
        .target(
            name: "SwiftTerm",
            path: "Sources/SwiftTerm",
            exclude: ["Mac/README.md"],
            resources: [.process("Apple/Metal/Shaders.metal")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
