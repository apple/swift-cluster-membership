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
import Synchronization

import struct Foundation.Date

@testable import SWIMNIOExample

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Real Networking Test Case

struct RealClustered {
    let session: ClusteredSession
    let group: MultiThreadedEventLoopGroup
    let loop: EventLoop

    init(
        session: ClusteredSession = .shared,
        group: MultiThreadedEventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 8)
    ) {
        self.session = session
        self.group = group
        self.loop = group.next()
    }

    func makeClusterNode(
        name: String? = nil,
        configure configureSettings: (inout SWIMNIO.Settings) -> Void = { _ in () }
    ) -> (SWIMNIOHandler, Channel) {
        let port = self.session.nextPort()
        let name = name ?? "swim-\(port)"
        var settings = SWIMNIO.Settings()
        configureSettings(&settings)

        if self.session.captureLogs {
            self.session.makeLogCapture(name: name, settings: &settings)
        }

        return self.session._storage.withLock { storage in
            let handler = SWIMNIOHandler(settings: settings)
            let bootstrap = DatagramBootstrap(group: self.group)
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .channelInitializer { channel in channel.pipeline.addHandler(handler) }

            let channel = try! bootstrap.bind(host: "127.0.0.1", port: port).wait()

            storage.shells.append(handler.shell)
            storage.nodes.append(handler.shell.node)

            return (handler, channel)
        }
    }

    func capturedLogs(of node: Node) -> LogCapture {
        self.session.capturedLogs(of: node)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Embedded Networking Test Case

struct EmbeddedClustered {
    let session: ClusteredSession
    let loop: EmbeddedEventLoop

    init(
        session: ClusteredSession = .shared,
        loop: EmbeddedEventLoop = EmbeddedEventLoop()
    ) {
        self.session = session
        self.loop = loop
    }

    func makeEmbeddedShell(
        _ _name: String? = nil,
        configure: (inout SWIMNIO.Settings) -> Void = { _ in () }
    ) -> SWIMNIOShell {
        var settings = SWIMNIO.Settings()
        configure(&settings)
        let node: Node
        if let _node = settings.swim.node {
            node = _node
        } else {
            let port = self.session.nextPort()
            let name = _name ?? "swim-\(port)"
            node = Node(protocol: "test", name: name, host: "127.0.0.1", port: port, uid: .random(in: 1..<UInt64.max))
        }

        if self.session.captureLogs {
            self.session.makeLogCapture(name: node.name ?? "swim-\(node.port)", settings: &settings)
        }

        return self.session._storage.withLock { storage in
            let channel = EmbeddedChannel(loop: self.loop)
            channel.isWritable = true
            let shell = SWIMNIOShell(
                node: node,
                settings: settings,
                channel: channel,
                onMemberStatusChange: { _ in () }  // TODO: store events so we can inspect them?
            )

            storage.nodes.append(shell.node)
            storage.shells.append(shell)

            return shell
        }
    }

    func capturedLogs(of node: Node) -> LogCapture {
        self.session.capturedLogs(of: node)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Base

final class ClusteredSession: Sendable {

    static let shared = ClusteredSession()

    struct Storage: Sendable {
        var nodes: [Node] = []
        var shells: [SWIMNIOShell] = []
        var logCaptures: [LogCapture] = []

        /// If `true` automatically captures all logs of all `setUpNode` started systems, and prints them if at least one test failure is encountered.
        /// If `false`, log capture is disabled and the systems will log messages normally.
        ///
        /// - Default: `true`
        var captureLogs: Bool = true
        /// Enables logging all captured logs, even if the test passed successfully.
        /// - Default: `false`
        var alwaysPrintCaptureLogs = false

        var nextPort = 9001
    }

    let _storage: Mutex<Storage> = Mutex(Storage())

    var captureLogs: Bool {
        self._storage.withLock { $0.captureLogs }
    }

    func nextPort() -> Int {
        self._storage.withLock { storage in
            defer { storage.nextPort += 1 }
            return storage.nextPort
        }
    }

    deinit {
        self._storage.withLock { storage in
            Task { [shells = storage.shells] in
                await withTaskGroup(of: Void.self) { group in
                    for shell in shells {
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
            }
            // TODO: Will print in any case right now, improve with shared count if failed tests
            //        let testsFailed = self.testRun?.totalFailureCount ?? 0 > 0
            if storage.captureLogs, storage.alwaysPrintCaptureLogs {
                //            || testsFailed {
                self.printAllCapturedLogs()
            }

            storage.nodes = []
            storage.logCaptures = []
        }
    }

    func makeLogCapture(name: String, settings: inout SWIMNIO.Settings) {
        let captureSettings = LogCapture.Settings()
        let capture = LogCapture(settings: captureSettings)

        settings.logger = capture.logger(label: name)

        self._storage.withLock { $0.logCaptures.append(capture) }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Captured Logs

extension ClusteredSession {
    public func capturedLogs(of node: Node) -> LogCapture {
        self._storage.withLock { storage in
            guard let index = storage.nodes.firstIndex(of: node) else {
                fatalError("No such node: [\(node)] in [\(storage.nodes)]!")
            }

            return storage.logCaptures[index]
        }
    }

    public func printCapturedLogs(of node: Node) {
        print("------------------------------------- \(node) ------------------------------------------------")
        self.capturedLogs(of: node).printLogs()
        print(
            "========================================================================================================================"
        )
    }

    public func printAllCapturedLogs() {
        self._storage.withLock { storage in
            for node in storage.nodes {
                self.printCapturedLogs(of: node)
            }
        }
    }
}
