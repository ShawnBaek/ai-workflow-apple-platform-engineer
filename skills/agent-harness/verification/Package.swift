// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ApplePlatformVerification",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "apple-verify", targets: ["AppleVerify"])],
    targets: [
        .target(name: "AppleVerificationCore"),
        .executableTarget(name: "AppleVerify", dependencies: ["AppleVerificationCore"]),
        .executableTarget(name: "ContentionProbe", dependencies: ["AppleVerificationCore"], path: "Tests/ContentionProbe"),
        .testTarget(name: "AppleVerificationCoreTests", dependencies: ["AppleVerificationCore", "ContentionProbe", "AppleVerify"])
    ]
)
