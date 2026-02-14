//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Cluster Membership open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Cluster Membership project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Cluster Membership project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import ClusterMembership
import Logging
import NIO
import NIOCore
import SWIM
import SWIMTestKit

import struct Foundation.Date

@testable import SWIMNIOExample

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Real Networking Test Case Cluster
actor RealCluster {
    private var storage: TestClusterStorage
    private let group: MultiThreadedEventLoopGroup
    private let loop: EventLoop

    fileprivate init(
        group: MultiThreadedEventLoopGroup,
        captureLogs: Bool,
        alwaysPrintCaptureLogs: Bool,
    ) {
        self.storage = TestClusterStorage(
            captureLogs: captureLogs,
            alwaysPrintCaptureLogs: alwaysPrintCaptureLogs
        )
        self.group = group
        self.loop = group.next()
    }

    fileprivate func shutdown(testFailed: Bool) async {
        await self.storage.clean(testFailed: testFailed)

        self.storage.nodes.removeAll()
        self.storage.shells.removeAll()
    }

    func makeClusterNode(
        name: String? = nil,
        configure configureSettings: (inout SWIMNIO.Settings) -> Void = { _ in () }
    ) async -> (SWIMNIOHandler, Channel) {
        let port = await PortGenerator.shared.nextPort()
        let name = name ?? "swim-\(port)"
        var settings = SWIMNIO.Settings()
        configureSettings(&settings)

        if self.storage.captureLogs {
            self.storage.makeLogCapture(name: name, settings: &settings)
        }

        let handler = SWIMNIOHandler(settings: settings)
        let bootstrap = DatagramBootstrap(group: self.group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in channel.pipeline.addHandler(handler) }

        let channel = try! await bootstrap.bind(host: "127.0.0.1", port: port).get()

        self.storage.shells.append(handler.shell)
        self.storage.nodes.append(handler.shell.node)

        return (handler, channel)
    }

    func capturedLogs(of node: Node) -> LogCapture {
        self.storage.capturedLogs(of: node)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Embedded Networking Test Case Cluster

actor EmbeddedCluster {
    private var storage: TestClusterStorage
    private let loop: EmbeddedEventLoop

    fileprivate init(
        loop: EmbeddedEventLoop,
        captureLogs: Bool,
        alwaysPrintCaptureLogs: Bool,
    ) {
        self.storage = TestClusterStorage(
            captureLogs: captureLogs,
            alwaysPrintCaptureLogs: alwaysPrintCaptureLogs
        )
        self.loop = loop
    }

    fileprivate func shutdown(testFailed: Bool) async {
        await self.storage.clean(testFailed: testFailed)

        self.storage.nodes.removeAll()
        self.storage.shells.removeAll()
    }

    func makeEmbeddedShell(
        _ _name: String? = nil,
        configure: (inout SWIMNIO.Settings) -> Void = { _ in () }
    ) async -> SWIMNIOShell {
        var settings = SWIMNIO.Settings()
        configure(&settings)
        let node: Node
        if let _node = settings.swim.node {
            node = _node
        } else {
            let port = await PortGenerator.shared.nextPort()
            let name = _name ?? "swim-\(port)"
            node = Node(protocol: "test", name: name, host: "127.0.0.1", port: port, uid: .random(in: 1..<UInt64.max))
        }

        if self.storage.captureLogs {
            self.storage.makeLogCapture(name: node.name ?? "swim-\(node.port)", settings: &settings)
        }

        let channel = EmbeddedChannel(loop: self.loop)
        channel.isWritable = true
        let shell = SWIMNIOShell(
            node: node,
            settings: settings,
            channel: channel,
            onMemberStatusChange: { _ in () }  // TODO: store events so we can inspect them?
        )

        self.storage.nodes.append(shell.node)
        self.storage.shells.append(shell)

        return shell
    }

    func capturedLogs(of node: Node) -> LogCapture {
        self.storage.capturedLogs(of: node)
    }

    func makeLogCapture(name: String, settings: inout SWIMNIO.Settings) {
        let captureSettings = LogCapture.Settings()
        let capture = LogCapture(settings: captureSettings)

        settings.logger = capture.logger(label: name)

        self.storage.logCaptures.append(capture)
    }

    func appendNode(_ node: Node) {
        self.storage.nodes.append(node)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Storage per cluster

struct TestClusterStorage: Sendable {

    var nodes: [Node] = []
    var shells: [SWIMNIOShell] = []
    var logCaptures: [LogCapture] = []

    /// If `true` automatically captures all logs of all `setUpNode` started systems, and prints them if at least one test failure is encountered.
    /// If `false`, log capture is disabled and the systems will log messages normally.
    ///
    /// - Default: `true`
    let captureLogs: Bool
    /// Enables logging all captured logs, even if the test passed successfully.
    /// - Default: `false`
    let alwaysPrintCaptureLogs: Bool

    init(
        captureLogs: Bool = true,
        alwaysPrintCaptureLogs: Bool = false
    ) {
        self.captureLogs = captureLogs
        self.alwaysPrintCaptureLogs = alwaysPrintCaptureLogs
    }

    func clean(testFailed: Bool) async {
        await withTaskGroup(of: Void.self) { group in
            for shell in self.shells {
                group.addTask {
                    do {
                        try await shell.myself.channel.close()
                    } catch {
                        ()  // channel was already closed, that's okey (e.g. we closed it in the test to "crash" a node)
                    }
                }
            }

            await group.waitForAll()
        }

        if self.captureLogs, self.alwaysPrintCaptureLogs || testFailed {
            self.printAllCapturedLogs()
        }
    }

    mutating func makeLogCapture(name: String, settings: inout SWIMNIO.Settings) {
        let captureSettings = LogCapture.Settings()
        let capture = LogCapture(settings: captureSettings)

        settings.logger = capture.logger(label: name)

        self.logCaptures.append(capture)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Captured Logs

extension TestClusterStorage {
    public func capturedLogs(of node: Node) -> LogCapture {
        guard let index = self.nodes.firstIndex(of: node) else {
            fatalError("No such node: [\(node)] in [\(self.nodes)]!")
        }

        return self.logCaptures[index]
    }

    public func printCapturedLogs(of node: Node) {
        print("------------------------------------- \(node) ------------------------------------------------")
        self.capturedLogs(of: node).printLogs()
        print(
            "========================================================================================================================"
        )
    }

    public func printAllCapturedLogs() {
        for node in self.nodes {
            self.printCapturedLogs(of: node)
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Shared, concurrency-safe port allocator for tests,

fileprivate actor PortGenerator {

    static let shared = PortGenerator()

    var _nextPort = 9001

    func nextPort() -> Int {
        defer { self._nextPort += 1 }
        return self._nextPort
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: `with` isolation functions to work with clusters in tests

/// Runs `body` with a fresh cluster and guarantees shutdown.
///
/// This helper provides structured lifetime management for tests:
/// - constructs a cluster for the duration of `body`
/// - ensures `shutdown()` is called on success *and* on failure
///

func withRealClusteredTestScope<T>(
    group: MultiThreadedEventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 8),
    captureLogs: Bool = true,
    alwaysPrintCaptureLogs: Bool = false,
    _ body: (RealCluster) async throws -> T
) async rethrows -> T {
    let cluster = RealCluster(
        group: group,
        captureLogs: captureLogs,
        alwaysPrintCaptureLogs: alwaysPrintCaptureLogs
    )
    do {
        let result = try await body(cluster)
        await cluster.shutdown(testFailed: false)
        return result
    } catch {
        await cluster.shutdown(testFailed: true)
        throw error
    }
}

func withEmbeddedClusteredTestScope<T>(
    loop: EmbeddedEventLoop = EmbeddedEventLoop(),
    captureLogs: Bool = true,
    alwaysPrintCaptureLogs: Bool = false,
    _ body: (EmbeddedCluster) async throws -> T,
) async rethrows -> T {
    let cluster = EmbeddedCluster(
        loop: loop,
        captureLogs: captureLogs,
        alwaysPrintCaptureLogs: alwaysPrintCaptureLogs
    )
    do {
        let result = try await body(cluster)
        await cluster.shutdown(testFailed: false)
        return result
    } catch {
        await cluster.shutdown(testFailed: true)
        throw error
    }
}
