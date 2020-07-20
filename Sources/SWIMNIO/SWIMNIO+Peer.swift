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
import Logging
import NIO
import SWIM
import struct SWIM.SWIMTimeAmount

extension SWIM {
    public struct NIOPeer: SWIMPeerProtocol, CustomStringConvertible {
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
            from origin: AddressableSWIMPeer,
            timeout: SWIMTimeAmount,
            onComplete: @escaping (Result<PingResponse, Error>) -> Void // FIXME: tricky, there is no real request reply here at all...
        ) {
            guard let channel = self.channel else {
                fatalError("\(#function) failed, channel was not initialized for \(self)!")
            }

            guard let nioOrigin = origin as? NIOPeer else {
                fatalError("Can't support non NIOPeer as origin, was: [\(origin)]:\(String(reflecting: type(of: origin as Any)))")
            }

            let message = SWIM.Message.ping(replyTo: nioOrigin, payload: payload)
            let proto = try! message.toProto() // FIXME: fix the try!
            let data = try! proto.serializedData() // FIXME: fix the try!

            channel.writeAndFlush(data, promise: nil)
            // FIXME: make the onComplete work, we need some seq nr maybe...
        }

        public func pingReq(
            target: AddressableSWIMPeer,
            payload: GossipPayload,
            from origin: AddressableSWIMPeer,
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

            let message = SWIM.Message.pingReq(target: nioTarget, replyTo: nioOrigin, payload: payload)
            let proto = try! message.toProto() // FIXME: fix the try!
            let data = try! proto.serializedData() // FIXME: fix the try!

            // FIXME: HOW TO MAKE THE TIMEOUT
            channel.eventLoop.scheduleTask(in: timeout.toNIO) {
                onComplete(.failure(PingTimeoutError(timeout: timeout, message: "pingReq timed out, no reply from [\(self)], target: [\(target)]")))
            }

            channel.writeAndFlush(data, promise: nil)
            // FIXME: make the onComplete work, we need some seq nr maybe...
        }

        public func ack(target: AddressableSWIMPeer, incarnation: Incarnation, payload: GossipPayload) {
            guard let channel = self.channel else {
                fatalError("\(#function) failed, channel was not initialized for \(self)!")
            }

            let message = SWIM.Message.response(.ack(target: target.node, incarnation: incarnation, payload: payload))
            let proto = try! message.toProto() // FIXME: fix the try!
            let data = try! proto.serializedData() // FIXME: fix the try!

            channel.writeAndFlush(data, promise: nil)
        }

        public func nack(target: AddressableSWIMPeer) {
            guard let channel = self.channel else {
                fatalError("\(#function) failed, channel was not initialized for \(self)!")
            }

            let message = SWIM.Message.response(.nack(target: target.node))
            let proto = try! message.toProto() // FIXME: fix the try!
            let data = try! proto.serializedData() // FIXME: fix the try!

            channel.writeAndFlush(data, promise: nil)
        }

        public var description: String {
            "NIOPeer(node: \(self.node), channel: \(self.channel))"
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

struct PingTimeoutError: Error {
    let timeout: SWIMTimeAmount
    let message: String

    init(timeout: SWIMTimeAmount, message: String) {
        self.timeout = timeout
        self.message = message
    }
}
