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
import Logging
import NIO
import SWIM
import struct SWIM.SWIMTimeAmount

// struct NIOSWIMContext: SWIM.Context {
////    let nioPeer: SWIM.NIOPeer
////    let eventLoop: EventLoop
////    var log: Logger
//
//    var peer: SWIMPeerProtocol {
//        self.nioPeer
//    }
//    var node: ClusterMembership.Node {
//        self.peer.node
//    }
//
//
//    init(myself: SWIM.NIOPeer, eventLoop: EventLoop, log: Logger) {
//        self.nioPeer = myself
//        self.eventLoop = eventLoop
//        self.log = log
//        self.log[metadataKey: "swim/node"] = "\(node)"
//    }
//
//    func peer(on node: Node) -> SWIMPeerProtocol {
//        if node == self.node {
//            return self.nioPeer
//        } else {
//            self.shell.
//        }
//    }
//
//
//    func startTimer(key: String, delay: SWIMTimeAmount, _ task: @escaping () -> Void) -> Cancellable {
//        let scheduled = self.eventLoop.scheduleTask(in: .nanoseconds(delay.nanoseconds), task)
//        return Cancellable {
//            scheduled.cancel()
//        }
//    }
// }
