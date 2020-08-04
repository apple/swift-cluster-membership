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
import NIOConcurrencyHelpers
import SWIM
import struct SWIM.SWIMTimeAmount

extension SWIM {
    public struct NIOPeer: SWIMPeerProtocol, CustomStringConvertible {
        public var node: Node

        // TODO: can we always have a channel here?
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
            from origin: SWIMAddressablePeer,
            timeout: SWIMTimeAmount,
            sequenceNumber: SWIM.SequenceNumber,
            onComplete: @escaping (Result<PingResponse, Error>) -> Void
        ) {
            guard let channel = self.channel else {
                fatalError("\(#function) failed, channel was not initialized for \(self)!")
            }

            guard let nioOrigin = origin as? NIOPeer else {
                fatalError("Can't support non NIOPeer as origin, was: [\(origin)]:\(String(reflecting: type(of: origin as Any)))")
            }

            let message = SWIM.Message.ping(replyTo: nioOrigin, payload: payload, sequenceNumber: sequenceNumber)

            let command = WriteCommand(message: message, to: self.node, replyTimeout: timeout.toNIO, replyCallback: { reply in
                switch reply {
                case .success(.response(let pingResponse)):
                    assert(sequenceNumber == pingResponse.sequenceNumber, "callback invoked with not matching sequence number! Submitted with \(sequenceNumber) but invoked with \(pingResponse.sequenceNumber)!")
                    onComplete(.success(pingResponse))
                case .failure(let error):
                    onComplete(.failure(error))

                case .success(let other):
                    fatalError("Unexpected message, got: [\(other)]:\(reflecting: type(of: other)) while expected \(PingResponse.self)")
                }
            })

            channel.writeAndFlush(command, promise: nil)
        }

        public func pingRequest(
            target: SWIMAddressablePeer,
            payload: GossipPayload,
            from origin: SWIMAddressablePeer,
            timeout: SWIMTimeAmount,
            sequenceNumber: SWIM.SequenceNumber,
            onComplete: @escaping (Result<PingResponse, Error>) -> Void
        ) {
            guard let channel = self.channel else {
                fatalError("\(#function) failed, channel was not initialized for \(self)!")
            }

            let targetPeer = NIOPeer(node: target.node, channel: nil)
            let originPeer = NIOPeer(node: origin.node, channel: nil)
            let message = SWIM.Message.pingRequest(target: targetPeer, replyTo: originPeer, payload: payload, sequenceNumber: sequenceNumber)

            let command = WriteCommand(message: message, to: self.node, replyTimeout: timeout.toNIO, replyCallback: { reply in
                switch reply {
                case .success(.response(let pingResponse)):
                    assert(sequenceNumber == pingResponse.sequenceNumber, "callback invoked with not matching sequence number! Submitted with \(sequenceNumber) but invoked with \(pingResponse.sequenceNumber)!")
                    onComplete(.success(pingResponse))
                case .failure(let error):
                    onComplete(.failure(error))

                case .success(let other):
                    fatalError("Unexpected message, got: \(other) while expected \(PingResponse.self)")
                }
            })

            channel.writeAndFlush(command, promise: nil)
        }

        public func ack(
            acknowledging sequenceNumber: SWIM.SequenceNumber,
            target: SWIMAddressablePeer,
            incarnation: Incarnation,
            payload: GossipPayload
        ) {
            guard let channel = self.channel else {
                fatalError("\(#function) failed, channel was not initialized for \(self)!")
            }

            let message = SWIM.Message.response(.ack(target: target.node, incarnation: incarnation, payload: payload, sequenceNumber: sequenceNumber))
            let command = WriteCommand(message: message, to: self.node, replyTimeout: .seconds(0), replyCallback: nil)

            channel.writeAndFlush(command, promise: nil)
        }

        public func nack(
            acknowledging sequenceNumber: SWIM.SequenceNumber,
            target: SWIMAddressablePeer
        ) {
            guard let channel = self.channel else {
                fatalError("\(#function) failed, channel was not initialized for \(self)!")
            }

            let message = SWIM.Message.response(.nack(target: target.node, sequenceNumber: sequenceNumber))
            let command = WriteCommand(message: message, to: self.node, replyTimeout: .seconds(0), replyCallback: nil)

            channel.writeAndFlush(command, promise: nil)
        }

        public var description: String {
            "NIOPeer(\(self.node), channel: \(self.channel != nil ? "<channel>" : "<nil>"))"
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

public struct SWIMNIOTimeoutError: Error, CustomStringConvertible {
    let timeout: SWIMTimeAmount
    let message: String

    init(timeout: NIO.TimeAmount, message: String) {
        self.timeout = SWIMTimeAmount.nanoseconds(timeout.nanoseconds)
        self.message = message
    }

    init(timeout: SWIMTimeAmount, message: String) {
        self.timeout = timeout
        self.message = message
    }

    public var description: String {
        "SWIMNIOTimeoutError(timeout: \(self.timeout.prettyDescription), \(self.message))"
    }
}
