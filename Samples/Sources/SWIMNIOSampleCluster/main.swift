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
import Metrics
import Prometheus
import SWIMNIOExample
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

    @Option(help: "Configures log level")
    var logLevel: String = "info"

    mutating func run() throws {
        LoggingSystem.bootstrap(_SWIMPrettyMetadataLogHandler.init)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

        // Uncomment this if you'd like to see metrics displayed in the command line periodically;
        // This bootstraps and uses the Prometheus metrics backend to report metrics periodically by printing them to the stdout (console).
        //
        // Note though that this will be a bit noisy, since logs are also emitted to the stdout by default, however it's a nice way
        // to learn and explore what the metrics are and how they behave when toying around with a local cluster.
//        let prom = PrometheusClient()
//        MetricsSystem.bootstrap(prom)
//
//        group.next().scheduleRepeatedTask(initialDelay: .seconds(1), delay: .seconds(10)) { _ in
//             prom.collect { (string: String) in
//                 print("")
//                 print("")
//                 print(string)
//             }
//        }
        
        let lifecycle = ServiceLifecycle()
        lifecycle.registerShutdown(
            label: "eventLoopGroup",
            .sync(group.syncShutdownGracefully)
        )

        var settings = SWIMNIO.Settings()
        if count == nil || count == 1 {
            let nodePort = self.port ?? 7001
            settings.logger = Logger(label: "swim-\(nodePort)")
            settings.logger.logLevel = self.parseLogLevel()
            settings.swim.logger.logLevel = self.parseLogLevel()

            settings.swim.initialContactPoints = self.parseContactPoints()

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
                settings.swim.initialContactPoints = self.parseContactPoints()

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

    private func parseLogLevel() -> Logger.Level {
        guard let level = Logger.Level.init(rawValue: self.logLevel) else {
            fatalError("Unknown log level: \(self.logLevel)")
        }
        return level
    }

    private func parseContactPoints() -> Set<ClusterMembership.Node> {
        guard self.initialContactPoints.trimmingCharacters(in: .whitespacesAndNewlines) != "" else {
            return []
        }
        
        let contactPoints: [Node] = self.initialContactPoints.split(separator: ",").map { hostPort in
            let host = String(hostPort.split(separator: ":")[0])
            let port = Int(String(hostPort.split(separator: ":")[1]))!

            return Node(protocol: "udp", host: host, port: port, uid: nil)
        }

        return Set(contactPoints)
    }
}

SWIMNIOSampleCluster.main()
