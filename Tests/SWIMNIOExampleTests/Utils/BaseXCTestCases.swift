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
import XCTest

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Real Networking Test Case

class RealClusteredXCTestCase: BaseClusteredXCTestCase {
    var group: MultiThreadedEventLoopGroup!
    var loop: EventLoop!

    override func setUp() {
        super.setUp()

        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 8)
        self.loop = group.next()
    }

    override func tearDown() {
        super.tearDown()

        try! self.group.syncShutdownGracefully()
        self.group = nil
        self.loop = nil
    }

    func makeClusterNode(name: String? = nil, configure configureSettings: (inout SWIMNIO.Settings) -> Void = { _ in () }) -> (SWIMNIOHandler, Channel) {
        let port = self.nextPort()
        let name = name ?? "swim-\(port)"
        var settings = SWIMNIO.Settings()
        configureSettings(&settings)

        if self.captureLogs {
            self.makeLogCapture(name: name, settings: &settings)
        }

        let handler = SWIMNIOHandler(settings: settings)
        let bootstrap = DatagramBootstrap(group: self.group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in channel.pipeline.addHandler(handler) }

        let channel = try! bootstrap.bind(host: "127.0.0.1", port: port).wait()

        self._shells.append(handler.shell)
        self._nodes.append(handler.shell.node)

        return (handler, channel)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Embedded Networking Test Case

class EmbeddedClusteredXCTestCase: BaseClusteredXCTestCase {
    var loop: EmbeddedEventLoop!

    open override func setUp() {
        super.setUp()

        self.loop = EmbeddedEventLoop()
    }

    open override func tearDown() {
        super.tearDown()

        try! self.loop.close()
        self.loop = nil
    }

    func makeEmbeddedShell(_ _name: String? = nil, configure: (inout SWIMNIO.Settings) -> Void = { _ in () }) -> SWIMNIOShell {
        var settings = SWIMNIO.Settings()
        configure(&settings)
        let node: Node
        if let _node = settings.swim.node {
            node = _node
        } else {
            let port = self.nextPort()
            let name = _name ?? "swim-\(port)"
            node = Node(protocol: "test", name: name, host: "127.0.0.1", port: port, uid: .random(in: 1 ..< UInt64.max))
        }

        if self.captureLogs {
            self.makeLogCapture(name: node.name ?? "swim-\(node.port)", settings: &settings)
        }

        let channel = EmbeddedChannel(loop: self.loop)
        channel.isWritable = true
        let shell = SWIMNIOShell(
            node: node,
            settings: settings,
            channel: channel,
            onMemberStatusChange: { _ in () } // TODO: store events so we can inspect them?
        )

        self._nodes.append(shell.node)
        self._shells.append(shell)

        return shell
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Base

class BaseClusteredXCTestCase: XCTestCase {
    public internal(set) var _nodes: [Node] = []
    public internal(set) var _shells: [SWIMNIOShell] = []
    public internal(set) var _logCaptures: [LogCapture] = []

    /// If `true` automatically captures all logs of all `setUpNode` started systems, and prints them if at least one test failure is encountered.
    /// If `false`, log capture is disabled and the systems will log messages normally.
    ///
    /// - Default: `true`
    open var captureLogs: Bool {
        true
    }

    /// Enables logging all captured logs, even if the test passed successfully.
    /// - Default: `false`
    open var alwaysPrintCaptureLogs: Bool {
        false
    }

    var _nextPort = 9001
    open func nextPort() -> Int {
        defer { self._nextPort += 1 }
        return self._nextPort
    }

    open func configureLogCapture(settings: inout LogCapture.Settings) {
        // just use defaults
    }

    open override func setUp() {
        super.setUp()

        self.addTeardownBlock {
            for shell in self._shells {
                do {
                    try await shell.myself.channel.close()
                } catch {
                    () // channel was already closed, that's okey (e.g. we closed it in the test to "crash" a node)
                }
            }
        }
    }

    open override func tearDown() {
        super.tearDown()

        let testsFailed = self.testRun?.totalFailureCount ?? 0 > 0
        if self.captureLogs, self.alwaysPrintCaptureLogs || testsFailed {
            self.printAllCapturedLogs()
        }

        self._nodes = []
        self._logCaptures = []
    }

    func makeLogCapture(name: String, settings: inout SWIMNIO.Settings) {
        var captureSettings = LogCapture.Settings()
        self.configureLogCapture(settings: &captureSettings)
        let capture = LogCapture(settings: captureSettings)

        settings.logger = capture.logger(label: name)

        self._logCaptures.append(capture)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Captured Logs

extension BaseClusteredXCTestCase {
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
