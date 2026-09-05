// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ApplePlatformVerification",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "AppleVerificationCore"),
        .testTarget(name: "AppleVerificationCoreTests", dependencies: ["AppleVerificationCore"])
    ]
)
