// swift-tools-version:5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

import class Foundation.ProcessInfo

// Workaround: Since we cannot include the flat just as command line options since then it applies to all targets,
// and ONE of our dependencies currently produces one warning, we have to use this workaround to enable it in _our_
// targets when the flag is set. We should remove the dependencies and then enable the flag globally though just by passing it.
let globalSwiftSettings: [SwiftSetting]
if ProcessInfo.processInfo.environment["WARNINGS_AS_ERRORS"] != nil {
    print("WARNINGS_AS_ERRORS enabled, passing `-warnings-as-errors`")
    globalSwiftSettings = [
        SwiftSetting.unsafeFlags(["-warnings-as-errors"])
    ]
} else {
    globalSwiftSettings = []
}

var targets: [PackageDescription.Target] = [
    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: SWIM

    .target(
        name: "ClusterMembership",
        dependencies: []
    ),

    .target(
        name: "SWIM",
        dependencies: [
            "ClusterMembership",
            .product(name: "Logging", package: "swift-log"),
            .product(name: "Metrics", package: "swift-metrics"),
        ]
    ),

    .target(
        name: "SWIMNIOExample",
        dependencies: [
            "SWIM",
            .product(name: "NIO", package: "swift-nio"),
            .product(name: "NIOFoundationCompat", package: "swift-nio"),
            .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            .product(name: "NIOExtras", package: "swift-nio-extras"),

            .product(name: "Logging", package: "swift-log"),
            .product(name: "Metrics", package: "swift-metrics"),
        ]
    ),

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Other Membership Protocols ...

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Documentation

    .testTarget(
        name: "ClusterMembershipDocumentationTests",
        dependencies: [
            "SWIM"
        ]
    ),

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Tests

    .testTarget(
        name: "ClusterMembershipTests",
        dependencies: [
            "ClusterMembership"
        ]
    ),

    .testTarget(
        name: "SWIMTests",
        dependencies: [
            "SWIM",
            "SWIMTestKit",
        ]
    ),

    .testTarget(
        name: "SWIMNIOExampleTests",
        dependencies: [
            "SWIMNIOExample",
            "SWIMTestKit",
        ]
    ),

    // NOT FOR PUBLIC CONSUMPTION.
    .testTarget(
        name: "SWIMTestKit",
        dependencies: [
            "SWIM",
            .product(name: "NIO", package: "swift-nio"),
            .product(name: "Logging", package: "swift-log"),
            .product(name: "Metrics", package: "swift-metrics"),
        ]
    ),

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Samples are defined in Samples/Package.swift
    // ==== ------------------------------------------------------------------------------------------------------------
]

var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.19.0"),
    .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.8.0"),
    .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.5.1"),

    // ~~~ SSWG APIs ~~~
    .package(url: "https://github.com/apple/swift-log.git", from: "1.4.0"),
    .package(url: "https://github.com/apple/swift-metrics.git", "2.3.2"..<"3.0.0"),  // since latest

]

let products: [PackageDescription.Product] = [
    .library(
        name: "ClusterMembership",
        targets: ["ClusterMembership"]
    ),
    .library(
        name: "SWIM",
        targets: ["SWIM"]
    ),
    .library(
        name: "SWIMNIOExample",
        targets: ["SWIMNIOExample"]
    ),
]

var package = Package(
    name: "swift-cluster-membership",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
    ],
    products: products,

    dependencies: dependencies,

    targets: targets.map { target in
        var swiftSettings = target.swiftSettings ?? []
        swiftSettings.append(contentsOf: globalSwiftSettings)
        if !swiftSettings.isEmpty {
            target.swiftSettings = swiftSettings
        }
        return target
    },

    cxxLanguageStandard: .cxx11
)

// ---    STANDARD CROSS-REPO SETTINGS DO NOT EDIT   --- //
for target in package.targets {
    switch target.type {
    case .regular, .test, .executable:
        var settings = target.swiftSettings ?? []
        // https://github.com/swiftlang/swift-evolution/blob/main/proposals/0444-member-import-visibility.md
        settings.append(.enableUpcomingFeature("MemberImportVisibility"))
        target.swiftSettings = settings
    case .macro, .plugin, .system, .binary:
        ()  // not applicable
    @unknown default:
        ()  // we don't know what to do here, do nothing
    }
}
// --- END: STANDARD CROSS-REPO SETTINGS DO NOT EDIT --- //
