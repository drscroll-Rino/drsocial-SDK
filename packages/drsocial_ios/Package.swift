// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DrSocial",
    // macOS only so `swift build` / `swift test` run on the Mac; the SDK is made for iOS 14+.
    platforms: [.iOS(.v14), .macOS(.v11)],
    products: [
        .library(name: "DrSocial", targets: ["DrSocial"]),
    ],
    targets: [
        .target(
            name: "DrSocial",
            path: "Sources/DrSocial",
            resources: [.copy("PrivacyInfo.xcprivacy")],
            swiftSettings: [.define("DRSOCIAL_SPM")]
        ),
        .testTarget(name: "DrSocialTests", dependencies: ["DrSocial"], path: "Tests/DrSocialTests"),
    ],
    swiftLanguageVersions: [.v5]
)
