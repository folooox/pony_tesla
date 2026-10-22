// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HistoryStoreHarness",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../ios/PonyCore")],
    targets: [
        .target(name: "HistoryStoreHarness", dependencies: [.product(name: "PonyCore", package: "PonyCore")]),
        .testTarget(name: "HistoryStoreHarnessTests", dependencies: ["HistoryStoreHarness", .product(name: "PonyCore", package: "PonyCore")])
    ]
)
