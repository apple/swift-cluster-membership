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

extension SWIM {
    public struct Peer: Hashable, SWIMPeerProtocol {
        public let node: Node
        let log: Logger
        let channel: Channel

        public init(node: Node, log: Logger, channel: Channel) {
            self.node = node
            self.channel = channel
        }

        public func ping(payload: GossipPayload, from origin: SWIMPeerProtocol, timeout: TimeAmount, onComplete: @escaping (Result<PingResponse, Error>) -> Void) {
            do {
                let message = SWIM.Message.remote(.ping(replyTo: origin, payload: payload))
                let proto = try message.toProto()
                let data = try proto.serializedData()

                self.channel.write(data)
                // FIXME: make the onComplete work, we need some seq nr maybe...
            } catch {
                self.log.warning("Failed to serialize message: \(payload)")
            }
        }

        public func pingReq(target: SWIMPeerProtocol, payload: GossipPayload, from origin: SWIMPeerProtocol, timeout: TimeAmount, onComplete: @escaping (Result<PingResponse, Error>) -> Void) {
            do {
                let message = SWIM.Message.remote(.pingReq(target: target, replyTo: origin, payload: payload))
                let proto = try message.toProto()
                let data = try proto.serializedData()

                self.channel.write(data)
                // FIXME: make the onComplete work, we need some seq nr maybe...
            } catch {
                self.log.warning("Failed to serialize message: \(payload)")
            }
        }

        public func ack(target: SWIMPeerProtocol, incarnation: Incarnation, payload: GossipPayload) {}

        public func nack(target: SWIMPeerProtocol) {}

        public func hash(into hasher: inout Hasher) {
            self.node.hash(into: &hasher)
        }

        public static func == (lhs: Peer<Message>, rhs: Peer<Message>) -> Bool {
            lhs.node == rhs.node
        }
    }
}
