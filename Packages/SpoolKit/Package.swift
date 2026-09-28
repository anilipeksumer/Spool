// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpoolKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SpoolKit", targets: ["SpoolKit"]),
    ],
    targets: [
        .target(name: "SpoolKit"),
        .testTarget(name: "SpoolKitTests", dependencies: ["SpoolKit"]),
    ]
)
