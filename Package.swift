// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EasySign",
    platforms: [.macOS(.v14)],
    products: [.library(name: "EasySignCore", targets: ["EasySignCore"])],
    targets: [
        .target(name: "EasySignCore"),
        .testTarget(name: "EasySignCoreTests", dependencies: ["EasySignCore"])
    ]
)
