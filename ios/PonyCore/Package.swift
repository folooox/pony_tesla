// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PonyCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "PonyCore", targets: ["PonyCore"])],
    targets: [.target(name: "PonyCore"), .testTarget(name: "PonyCoreTests", dependencies: ["PonyCore"])]
)
