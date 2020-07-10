//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Cluster Membership open source project
//
// Copyright (c) 2018-2020 Apple Inc. and the Swift Cluster Membership project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Cluster Membership project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

// tag::cluster-sample[]
import ClusterMembership
import SWIM
import NIO
import Logging
// end::cluster-sample[]


func startNode(port: Int) {
    let logger = Logger(label: "swim-\(port)")

    let elg = MultiThreadedEventLoopGroup(numberOfThreads: 3)
    let node = ClusterMembership.Node(protocol: "tcp", host: "127.0.0.1", port: port, uid: .random(in: 0..<UInt64.max))

    NIOSWIMShell()

    let myself = Peer<SWIM.Message>(node: node)
    let settings = SWIM.Settings()

    SWIM.Instance(settings: settings, myself: myself)
}

startNode(7001)
startNode(7002)
startNode(7003)
startNode(7004)

