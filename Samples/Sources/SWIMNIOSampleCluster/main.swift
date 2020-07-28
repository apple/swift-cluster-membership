//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Cluster Membership open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift Cluster Membership project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Cluster Membership project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import ClusterMembership
import SWIM
import SWIMNIO
import NIO
import Logging
import Lifecycle
import ArgumentParser

struct SWIMNIOSampleCluster: ParsableCommand {
    @Option(name: .shortAndLong, help: "The number of nodes to start, defaults to: 1")
    var count: Int?

    @Argument(help: "Hostname that node(s) should bind to")
    var host: String?
    
    @Option(help: "Determines which this node should bind to; Only effective when running a single node")
    var port: Int?

    @Option(help: "Configures which nodes should be passed in as initial contact points, format: host:port,")
    var initialContactPoints: String = ""

    mutating func run() throws {
        LoggingSystem.bootstrap(_PrettyMetadataLogHandler.init)

        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        
        let lifecycle = ServiceLifecycle()
        lifecycle.registerShutdown(
            label: "eventLoopGroup",
            .sync(group.syncShutdownGracefully)
        )

        var settings = SWIM.Settings()
        if count == nil || count == 1 {
            let nodePort = self.port ?? 7001
            settings.logger = Logger(label: "swim-\(nodePort)")
            settings.logger.logLevel = .trace
            settings.initialContactPoints = self.parseContactPoints()

            let node = SampleSWIMNIONode(port: nodePort, settings: settings, group: group)
            lifecycle.register(
                label: "swim-\(nodePort)",
                start: .sync { node.start() },
                shutdown: .sync {}
            )

        } else {
            let basePort = port ?? 7001
            for i in 1...(count ?? 1) {
                let nodePort = basePort + i

                settings.logger = Logger(label: "swim-\(nodePort)")
                settings.logger.logLevel = .trace
                settings.initialContactPoints = self.parseContactPoints()

                let node = SampleSWIMNIONode(
                    port: nodePort,
                    settings: settings,
                    group: group
                )

                lifecycle.register(
                    label: "swim\(nodePort)",
                    start: .sync { node.start() },
                    shutdown: .sync {}
                )
            }
        }
        
        try lifecycle.startAndWait()
    }

    private func parseContactPoints() -> [ClusterMembership.Node] {
        guard self.initialContactPoints.trimmingCharacters(in: .whitespacesAndNewlines) != "" else {
            return []
        }
        
        return self.initialContactPoints.split(separator: ",").map { hostPort in
            let host: String
            if hostPort.starts(with: ":") {
                host = self.host ?? "127.0.0.1"
            } else {
                host = String(hostPort.split(separator: ":")[0])
            }
            let port = Int(String(hostPort.split(separator: ":")[1]))!

            return Node(protocol: "udp", host: host, port: port, uid: nil)
        }
    }
}

SWIMNIOSampleCluster.main()
