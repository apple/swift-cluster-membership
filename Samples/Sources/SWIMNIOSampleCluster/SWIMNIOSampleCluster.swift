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

import ArgumentParser
import ClusterMembership
import Logging
import Metrics
import NIO
import SWIM
import SWIMNIOExample
import ServiceLifecycle

@main
struct SWIMNIOSampleCluster: AsyncParsableCommand {

  @Option(name: .shortAndLong, help: "The number of nodes to start, defaults to: 1")
  var count: Int = 1

  //    @Argument(help: "Hostname that node(s) should bind to")
  //    var host: String?

  @Option(
    help: "Determines which this node should bind to; Only effective when running a single node")
  var port: Int = 7001

  @Option(
    help: "Configures which nodes should be passed in as initial contact points, format: host:port,"
  )
  var initialContactPoints: String = ""

  @Option(help: "Configures log level")
  var logLevel: String = "info"

  func run() async throws {
    LoggingSystem.bootstrap(_SWIMPrettyMetadataLogHandler.init)
    let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

    // FIXME: Update Prometheus client
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

    var services: [any Service] = []
    var settings = SWIMNIO.Settings()
    if self.count == 1 {
      let nodePort = self.port
      settings.logger = Logger(label: "swim-\(nodePort)")
      settings.logger.logLevel = self.parseLogLevel()
      settings.swim.logger.logLevel = self.parseLogLevel()

      settings.swim.initialContactPoints = self.parseContactPoints()
      services.append(
        SampleSWIMNIONode(
          port: nodePort,
          settings: settings,
          group: group
        )
      )
    } else {
      let basePort = port
      for i in 1...count {
        let nodePort = basePort + i

        settings.logger = Logger(label: "swim-\(nodePort)")
        settings.swim.initialContactPoints = self.parseContactPoints()

        services.append(
          SampleSWIMNIONode(
            port: nodePort,
            settings: settings,
            group: group
          )
        )
      }
    }
    let serviceGroup = ServiceGroup(
      services: services,
      logger: .init(label: "swim")
    )
    try await serviceGroup.run()
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
