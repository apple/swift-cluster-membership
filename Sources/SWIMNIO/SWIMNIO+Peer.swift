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

extension SWIM {
    public struct NIOPeer: SWIMPeerProtocol {
        public let node: Node

        var channel: Channel?

        public init(node: Node, channel: Channel?) {
            self.node = node
            self.channel = channel
        }

        public mutating func associateWith(channel: Channel) {
            assert(self.channel == nil, "Tried to associate \(channel) with already associated \(self)")
            self.channel = channel
        }

        public func ping(
            payload: GossipPayload,
            from origin: SWIMPeerProtocol,
            timeout: SWIMTimeAmount,
            onComplete: @escaping (Result<PingResponse, Error>) -> Void
        ) {
            guard let channel = self.channel else {
                fatalError("\(#function) failed, channel was not initialized for \(self)!")
            }

            guard let nioOrigin = origin as? NIOPeer else {
                fatalError("Can't support non NIOPeer as origin, was: [\(origin)]:\(String(reflecting: type(of: origin as Any)))")
            }

            let message = SWIM.RemoteMessage.ping(replyTo: nioOrigin, payload: payload)
            let proto = try! message.toProto() // FIXME: fix the try!
            let data = try! proto.serializedData() // FIXME: fix the try!

            channel.write(data)
            // FIXME: make the onComplete work, we need some seq nr maybe...
        }

        public func pingReq(
            target: SWIMPeerProtocol,
            payload: GossipPayload,
            from origin: SWIMPeerProtocol,
            timeout: SWIMTimeAmount, // FIXME: maybe deadlines?
            onComplete: @escaping (Result<PingResponse, Error>) -> Void
        ) {
            guard let channel = self.channel else {
                fatalError("\(#function) failed, channel was not initialized for \(self)!")
            }
            guard let nioTarget = target as? SWIM.NIOPeer else {
                fatalError("\(#function) failed, `target` was not `NIOPeer`, was: \(target)")
            }
            guard let nioOrigin = origin as? SWIM.NIOPeer else {
                fatalError("\(#function) failed, `origin` was not `NIOPeer`, was: \(origin)")
            }

            let message = SWIM.RemoteMessage.pingReq(target: nioTarget, replyTo: nioOrigin, payload: payload)
            let proto = try! message.toProto() // FIXME: fix the try!
            let data = try! proto.serializedData() // FIXME: fix the try!

            channel.write(data)
            // FIXME: make the onComplete work, we need some seq nr maybe...
        }

        public func ack(target: SWIMPeerProtocol, incarnation: Incarnation, payload: GossipPayload) {
            guard let channel = self.channel else {
                fatalError("\(#function) failed, channel was not initialized for \(self)!")
            }

            fatalError()
        }

        public func nack(target: SWIMPeerProtocol) {
            guard let channel = self.channel else {
                fatalError("\(#function) failed, channel was not initialized for \(self)!")
            }

            fatalError()
        }
    }
}

extension SWIM.NIOPeer: Hashable {
    public func hash(into hasher: inout Hasher) {
        self.node.hash(into: &hasher)
    }

    public static func == (lhs: SWIM.NIOPeer, rhs: SWIM.NIOPeer) -> Bool {
        lhs.node == rhs.node
    }
}
