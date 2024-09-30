//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Cluster Membership open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Cluster Membership project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Cluster Membership project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import ClusterMembership
import struct Foundation.Date
import class Foundation.NSLock
import Logging
import NIO
import NIOCore
import SWIM
@testable import SWIMNIOExample
import SWIMTestKit
import Testing

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Real Networking Test Case

final class RealClustered {
    let clustered: Clustered
    var group: MultiThreadedEventLoopGroup!
    var loop: EventLoop!
    
    /// If `true` automatically captures all logs of all `setUpNode` started systems, and prints them if at least one test failure is encountered.
    /// If `false`, log capture is disabled and the systems will log messages normally.
    ///
    /// - Default: `true`
    var captureLogs: Bool { true }

    /// Enables logging all captured logs, even if the test passed successfully.
    /// - Default: `false`
    var alwaysPrintCaptureLogs: Bool { false }
    
    init(startingPort: Int) {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 8)
        self.loop = group.next()
        self.clustered = .init(startingPort: startingPort)
    }

    deinit {
        try! self.group.syncShutdownGracefully()
        self.group = nil
        self.loop = nil
        Task { [clustered] in
            await clustered.reset()
        }
    }

    func makeClusterNode(
        name: String? = nil,
        configure configureSettings: (inout SWIMNIO.Settings) -> Void = { _ in () }
    ) async throws -> (SWIMNIOHandler, Channel) {
        let port = await clustered.nextPort()
        let name = name ?? "swim-\(port)"
        var settings = SWIMNIO.Settings()
        configureSettings(&settings)

        if self.captureLogs {
            await clustered.makeLogCapture(name: name, settings: &settings)
        }

        let handler = SWIMNIOHandler(settings: settings)
        let bootstrap = DatagramBootstrap(group: self.group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in channel.pipeline.addHandler(handler) }

        let channel = try await bootstrap.bind(host: "127.0.0.1", port: port).get()

        await clustered.addShell(handler.shell)
        await clustered.addNode(handler.shell.node)

        return (handler, channel)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Embedded Networking Test Case

final class EmbeddedClustered {
    let clustered: Clustered
    var loop: EmbeddedEventLoop!
    
    /// If `true` automatically captures all logs of all `setUpNode` started systems, and prints them if at least one test failure is encountered.
    /// If `false`, log capture is disabled and the systems will log messages normally.
    ///
    /// - Default: `true`
    var captureLogs: Bool { true }

    /// Enables logging all captured logs, even if the test passed successfully.
    /// - Default: `false`
    var alwaysPrintCaptureLogs: Bool { false }

    
    init(startingPort: Int) {
        self.loop = EmbeddedEventLoop()
        self.clustered = .init(startingPort: startingPort)
    }

    deinit {
        try! self.loop.close()
        self.loop = nil
        Task { [clustered] in
            await clustered.reset()
        }
    }

    func makeEmbeddedShell(_ _name: String? = nil, configure: (inout SWIMNIO.Settings) -> Void = { _ in () }) async -> SWIMNIOShell {
        var settings = SWIMNIO.Settings()
        configure(&settings)
        let node: Node
        if let _node = settings.swim.node {
            node = _node
        } else {
            let port = await clustered.nextPort()
            let name = _name ?? "swim-\(port)"
            node = Node(protocol: "test", name: name, host: "127.0.0.2", port: port, uid: .random(in: 1 ..< UInt64.max))
        }

        if self.captureLogs {
            await clustered.makeLogCapture(name: node.name ?? "swim-\(node.port)", settings: &settings)
        }

        let channel = EmbeddedChannel(loop: self.loop)
        channel.isWritable = true
        let shell = SWIMNIOShell(
            node: node,
            settings: settings,
            channel: channel,
            onMemberStatusChange: { _ in () } // TODO: store events so we can inspect them?
        )

        await self.clustered.addNode(shell.node)
        await self.clustered.addShell(shell)

        return shell
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Base
// FIXME: Give better naming
actor Clustered {
    public internal(set) var _nodes: [Node] = []
    public internal(set) var _shells: [SWIMNIOShell] = []
    public internal(set) var _logCaptures: [LogCapture] = []

    var _nextPort = 9001
    
    // Because tests are parallel now—testing will fail as same ports will occur. For now passing different starting ports.
    // FIXME: Don't pass starting port probably, come up with better design.
    init(startingPort: Int = 9001) {
        self._nextPort = startingPort
    }
    
    func nextPort() -> Int {
        let port = self._nextPort
        self._nextPort += 1
        return port
    }

    func configureLogCapture(settings: inout LogCapture.Settings) {
        // just use defaults
    }

    func makeLogCapture(name: String, settings: inout SWIMNIO.Settings) {
        var captureSettings = LogCapture.Settings()
        self.configureLogCapture(settings: &captureSettings)
        let capture = LogCapture(settings: captureSettings)

        settings.logger = capture.logger(label: name)

        self._logCaptures.append(capture)
    }
    
    func reset() async {
        for shell in _shells {
            do {
                try await shell.myself.channel.close()
            } catch {
                () // channel was already closed, that's okey (e.g. we closed it in the test to "crash" a node)
            }
        }
        self._shells.removeAll()
        self._nodes.removeAll()
    }
    
    func addShell(_ shell: SWIMNIOShell) {
        self._shells.append(shell)
    }
    
    func addNode(_ node: Node) {
        self._nodes.append(node)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Captured Logs

extension Clustered {
    public func capturedLogs(of node: Node) -> LogCapture {
        guard let index = self._nodes.firstIndex(of: node) else {
            fatalError("No such node: [\(node)] in [\(self._nodes)]!")
        }

        return self._logCaptures[index]
    }

    public func printCapturedLogs(of node: Node) {
        print("------------------------------------- \(node) ------------------------------------------------")
        self.capturedLogs(of: node).printLogs()
        print("========================================================================================================================")
    }

    public func printAllCapturedLogs() {
        for node in self._nodes {
            self.printCapturedLogs(of: node)
        }
    }
}
