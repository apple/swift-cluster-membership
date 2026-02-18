// swift-tools-version:6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

var targets: [PackageDescription.Target] = [
    .executableTarget(
        name: "SWIMNIOSampleCluster",
        dependencies: [
            .product(name: "SWIM", package: "swift-cluster-membership"),
            .product(name: "SWIMNIOExample", package: "swift-cluster-membership"),
            .product(name: "Prometheus", package: "swift-prometheus"),
            .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]
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

    .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.9.0"),
    .package(url: "https://github.com/swift-server/swift-prometheus", from: "2.2.0"),
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.7.0"),
]

let package = Package(
    name: "swift-cluster-membership-samples",
    platforms: [
        .macOS(.v15)
    ],
    products: [],
    dependencies: dependencies,
    targets: targets,
    cxxLanguageStandard: .cxx11
)
