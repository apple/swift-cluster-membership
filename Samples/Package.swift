// swift-tools-version:5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

var targets: [PackageDescription.Target] = [
    .target(
        name: "SWIMNIOSampleCluster",
        dependencies: [
            .product(name: "SWIM", package: "swift-cluster-membership"),
            .product(name: "SWIMNIOExample", package: "swift-cluster-membership"),
            .product(name: "SwiftPrometheus", package: "SwiftPrometheus"),
            .product(name: "Lifecycle", package: "swift-service-lifecycle"),
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ],
        path: "Sources/SWIMNIOSampleCluster"
    ),

    /* --- tests --- */

    // no-tests placeholder project to not have `swift test` fail on Samples/
    .testTarget(
        name: "NoopTests",
        dependencies: [
            .product(name: "SWIM", package: "swift-cluster-membership")
        ],
        path: "Tests/NoopTests"
    ),
]

var dependencies: [Package.Dependency] = [
    // ~~~~~~~     parent       ~~~~~~~
    .package(path: "../"),

    // ~~~~~~~ only for samples ~~~~~~~

    .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "1.0.0-alpha"),
    .package(url: "https://github.com/MrLotU/SwiftPrometheus.git", from: "1.0.0-alpha"),
    .package(url: "https://github.com/apple/swift-argument-parser", from: "0.2.0"),
]

let package = Package(
    name: "swift-cluster-membership-samples",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "SWIMNIOSampleCluster",
            targets: ["SWIMNIOSampleCluster"]
        )

    ],

    dependencies: dependencies,

    targets: targets,

    cxxLanguageStandard: .cxx11
)
