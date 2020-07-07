// swift-tools-version:5.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

var targets: [PackageDescription.Target] = [
    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Samples

    .target(
        name: "SampleCluster",
        dependencies: ["SWIM"],
        path: "Sources/SampleCluster"
    ),

    /* --- tests --- */

    // no-tests placeholder project to not have `swift test` fail on Samples/
    .testTarget(
        name: "NoopTests",
        dependencies: [
            "SWIM",
        ],
        path: "Tests/NoopTests"
    ),
]

var dependencies: [Package.Dependency] = [
    // ~~~~~~~     parent       ~~~~~~~
    .package(path: "../"),

    // ~~~~~~~ only for samples ~~~~~~~

    // for metrics examples:
    .package(url: "https://github.com/MrLotU/SwiftPrometheus", from: "1.0.0-alpha.5"), // Apache v2 license
]

let package = Package(
    name: "swift-cluster-membership-samples",
    products: [
        /* ---  samples --- */

        .executable(
            name: "SampleCluster",
            targets: ["SampleCluster"]
        ),

    ],

    dependencies: dependencies,

    targets: targets,

    cxxLanguageStandard: .cxx11
)
