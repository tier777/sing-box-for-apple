// swift-tools-version: 5.9
import PackageDescription

// Small, entitlement-free state-machine tests; the shipping app remains Xcode.
let package = Package(
    name: "SFMRouteHealthTests",
    platforms: [.macOS(.v13)],
    products: [.library(name: "RouteHealthCore", targets: ["RouteHealthCore"])],
    targets: [
        .target(name: "RouteHealthCore", path: "Library/Network", sources: ["RouteHealthState.swift", "ProfileRulesDocument.swift"]),
        .testTarget(name: "RouteHealthCoreTests", dependencies: ["RouteHealthCore"], path: "Tests/RouteHealthCoreTests"),
    ]
)
