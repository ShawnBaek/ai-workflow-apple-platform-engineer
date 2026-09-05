// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ApplePlatformVerification",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "AppleVerificationCore"),
        .executableTarget(name: "ContentionProbe", dependencies: ["AppleVerificationCore"], path: "Tests/ContentionProbe"),
        .testTarget(name: "AppleVerificationCoreTests", dependencies: ["AppleVerificationCore", "ContentionProbe"])
    ]
)
