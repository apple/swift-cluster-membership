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

import ClusterMembership
import NIO
import Logging

final class NIOSWIMContext: SWIMContext {
    let node: ClusterMembership.Node
    let eventLoop: EventLoop

    var log: Logger

    init(node: ClusterMembership.Node, eventLoop: EventLoop, log: Logger) {
        self.node = node
        self.eventLoop = eventLoop
        self.log = log
        self.log[metadataKey: "swim/node"] = "\(node)"
    }

    var peer: SWIMPeerProtocol {
        SWIM.Peer(node: self.node, sendMessage: <#T##@escaping (Message) -> ()##@escaping (SWIM.SWIM.Message) -> ()#>)
    }

    func startTimer(key: String, delay: TimeAmount, _ task: @escaping () -> Void) -> Cancellable {
        let scheduled = self.eventLoop.scheduleTask(in: .nanoseconds(delay.nanoseconds), task)
        return Cancellable {
            scheduled.cancel()
        }
    }
}