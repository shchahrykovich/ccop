// swift-tools-version: 6.0
// ccop menu bar app. Built with `swift build`; scripts/build-app.sh
// assembles CCOP.app around it with the Rust CLI.
import PackageDescription

let package = Package(
    name: "CCOP",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CCOP", targets: ["CCOP"]),
    ],
    targets: [
        // Everything that can be tested without a UI: session types, the
        // CLI runner, filters, totals, formatting.
        .target(name: "CCOPKit"),
        .executableTarget(name: "CCOP", dependencies: ["CCOPKit"]),
        .testTarget(name: "CCOPKitTests", dependencies: ["CCOPKit"]),
    ]
)
