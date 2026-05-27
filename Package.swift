// swift-tools-version:6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

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

            .product(name: "Logging", package: "swift-log"),
            .product(name: "Metrics", package: "swift-metrics"),
            .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
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
    .target(
        name: "SWIMTestKit",
        dependencies: [
            "SWIM",
            .product(name: "NIO", package: "swift-nio"),
            .product(name: "Logging", package: "swift-log"),
            .product(name: "MetricsTestKit", package: "swift-metrics"),
        ]
    ),

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Samples are defined in Samples/Package.swift
    // ==== ------------------------------------------------------------------------------------------------------------
]

var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.100.0"),

    // ~~~ SSWG APIs ~~~
    .package(url: "https://github.com/apple/swift-log.git", from: "1.13.0"),
    .package(url: "https://github.com/apple/swift-metrics.git", "2.10.0"..<"3.0.0"),  // since latest
    .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.9.0"),

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
        .macOS(.v15),
        .iOS(.v18),
        .tvOS(.v18),
        .watchOS(.v11),
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
let upcomingConcurrencySettings: [SwiftSetting] = [
    .enableUpcomingFeature("MemberImportVisibility"),  // SE-0444
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),  // SE-0461
    .enableUpcomingFeature("InferIsolatedConformances"),  // SE-0470
    .enableUpcomingFeature("ImmutableWeakCaptures"),  // SE-0481
]

for target in package.targets {
    switch target.type {
    case .regular, .test, .executable:
        var settings = target.swiftSettings ?? []
        settings.append(contentsOf: upcomingConcurrencySettings)
        target.swiftSettings = settings
    case .macro, .plugin, .system, .binary:
        ()  // not applicable
    @unknown default:
        ()  // we don't know what to do here, do nothing
    }
}
// --- END: STANDARD CROSS-REPO SETTINGS DO NOT EDIT --- //
