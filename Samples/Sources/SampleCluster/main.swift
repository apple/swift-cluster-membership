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
import Lifecycle
import NIO
import Logging

let lifecycle = ServiceLifecycle()

let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
lifecycle.registerShutdown(
    label: "eventLoopGroup",
    .sync(group.syncShutdownGracefully)
)

LoggingSystem.bootstrap(_PrettyMetadataLogHandler.init)

let log = Logger(label: "SampleCluster")

func startNode(port: Int) {
    var settings = SWIM.Settings()
    if port == 7002 {
        settings.logger = Logger(label: "swim-\(port)")
    } else {
        settings.logger = Logger(label: "swim-\(port)", factory: { _ in SwiftLogNoOpLogHandler() })
    }
    settings.logger.logLevel = .trace
    settings.initialContactPoints = [
        Node(protocol: "udp", host: "127.0.0.1", port: 7001, uid: nil)
    ]

    let bootstrap = DatagramBootstrap(group: group)
        .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        .channelInitializer { channel in
            channel.pipeline.addHandler(SWIMProtocolHandler(settings: settings, group: group))
        }

    lifecycle.register(
        label: "swim-\(port)",
        start: .async { complete in
            bootstrap.bind(host: "127.0.0.1", port: port).whenComplete { result in
                switch result {
                case .failure(let error): complete(error)
                default: complete(nil)
                }
            }
        },
        shutdown: .sync { } // TODO: allow the start to pass through the value here
    )
}

startNode(port: 7001)
startNode(port: 7002)
startNode(port: 7003)
startNode(port: 7004)

lifecycle.start { error in
    if let error = error {
        log.error("failed to start ☠️: \(error)")
    } else {
        log.info("started successfully 🚀")
    }
}

lifecycle.wait()
