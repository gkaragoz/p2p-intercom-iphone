// swift-tools-version:5.9
//
// This manifest exposes the platform-independent part of the app (`Intercom/Core`) as a
// Swift package so it can be unit-tested with `swift test` on any platform, including Linux CI.
// The Xcode project compiles the very same files directly into the app target.
import PackageDescription

let package = Package(
    name: "IntercomCore",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "IntercomCore", targets: ["IntercomCore"]),
    ],
    targets: [
        .target(
            name: "IntercomCore",
            path: "Intercom/Core"
        ),
        .testTarget(
            name: "IntercomCoreTests",
            dependencies: ["IntercomCore"],
            path: "Tests/IntercomCoreTests"
        ),
    ]
)
