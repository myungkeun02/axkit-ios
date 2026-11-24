// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AxKitCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "AxKitCore", targets: ["AxKitCore"])],
    targets: [
        .target(name: "AxKitCore"),
        .testTarget(name: "AxKitCoreTests", dependencies: ["AxKitCore"]),
    ]
)
