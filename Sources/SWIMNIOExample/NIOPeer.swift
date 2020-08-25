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
import Dispatch
import Logging
import NIO
import NIOConcurrencyHelpers
import SWIM

extension SWIM {
    /// SWIMPeer designed to deliver messages over UDP in collaboration with the SWIMNIOHandler.
    public struct NIOPeer: SWIMPeer, SWIMPingOriginPeer, SWIMPingRequestOriginPeer, CustomStringConvertible {
        public var node: Node

        internal var channel: Channel

        public init(node: Node, channel: Channel) {
            self.node = node
            self.channel = channel
        }

        public func ping(
            payload: GossipPayload,
            from origin: SWIMPingOriginPeer,
            timeout: DispatchTimeInterval,
            sequenceNumber: SWIM.SequenceNumber,
            onResponse: @escaping (Result<PingResponse, Error>) -> Void
        ) {
            guard let originPeer = origin as? SWIM.NIOPeer else {
                fatalError("Peers MUST be of type SWIM.NIOPeer, yet was: \(origin)")
            }
            let message = SWIM.Message.ping(replyTo: originPeer, payload: payload, sequenceNumber: sequenceNumber)

            let command = SWIMNIOWriteCommand(message: message, to: self.node, replyTimeout: timeout.toNIO, replyCallback: { reply in
                switch reply {
                case .success(.response(let pingResponse)):
                    assert(sequenceNumber == pingResponse.sequenceNumber, "callback invoked with not matching sequence number! Submitted with \(sequenceNumber) but invoked with \(pingResponse.sequenceNumber)!")
                    onResponse(.success(pingResponse))
                case .failure(let error):
                    onResponse(.failure(error))

                case .success(let other):
                    fatalError("Unexpected message, got: [\(other)]:\(reflecting: type(of: other)) while expected \(PingResponse.self)")
                }
            })

            self.channel.writeAndFlush(command, promise: nil)
        }

        public func pingRequest(
            target: SWIMAddressablePeer,
            payload: GossipPayload,
            from origin: SWIMPingRequestOriginPeer,
            timeout: DispatchTimeInterval,
            sequenceNumber: SWIM.SequenceNumber,
            onResponse: @escaping (Result<PingResponse, Error>) -> Void
        ) {
            guard let targetPeer = target as? SWIM.NIOPeer else {
                fatalError("Peers MUST be of type SWIM.NIOPeer, yet was: \(target)")
            }
            guard let originPeer = origin as? SWIM.NIOPeer else {
                fatalError("Peers MUST be of type SWIM.NIOPeer, yet was: \(origin)")
            }
            let message = SWIM.Message.pingRequest(target: targetPeer, replyTo: originPeer, payload: payload, sequenceNumber: sequenceNumber)

            let command = SWIMNIOWriteCommand(message: message, to: self.node, replyTimeout: timeout.toNIO, replyCallback: { reply in
                switch reply {
                case .success(.response(let pingResponse)):
                    assert(sequenceNumber == pingResponse.sequenceNumber, "callback invoked with not matching sequence number! Submitted with \(sequenceNumber) but invoked with \(pingResponse.sequenceNumber)!")
                    onResponse(.success(pingResponse))
                case .failure(let error):
                    onResponse(.failure(error))

                case .success(let other):
                    fatalError("Unexpected message, got: \(other) while expected \(PingResponse.self)")
                }
            })

            self.channel.writeAndFlush(command, promise: nil)
        }

        public func ack(
            acknowledging sequenceNumber: SWIM.SequenceNumber,
            target: SWIMAddressablePeer,
            incarnation: Incarnation,
            payload: GossipPayload
        ) {
            let message = SWIM.Message.response(.ack(target: target, incarnation: incarnation, payload: payload, sequenceNumber: sequenceNumber))
            let command = SWIMNIOWriteCommand(message: message, to: self.node, replyTimeout: .seconds(0), replyCallback: nil)

            self.channel.writeAndFlush(command, promise: nil)
        }

        public func nack(
            acknowledging sequenceNumber: SWIM.SequenceNumber,
            target: SWIMAddressablePeer
        ) {
            let message = SWIM.Message.response(.nack(target: target, sequenceNumber: sequenceNumber))
            let command = SWIMNIOWriteCommand(message: message, to: self.node, replyTimeout: .seconds(0), replyCallback: nil)

            self.channel.writeAndFlush(command, promise: nil)
        }

        public var description: String {
            "NIOPeer(\(self.node))"
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
    let timeout: DispatchTimeInterval
    let message: String

    init(timeout: NIO.TimeAmount, message: String) {
        self.timeout = .nanoseconds(Int(timeout.nanoseconds))
        self.message = message
    }

    init(timeout: DispatchTimeInterval, message: String) {
        self.timeout = timeout
        self.message = message
    }

    public var description: String {
        "SWIMNIOTimeoutError(timeout: \(self.timeout.prettyDescription), \(self.message))"
    }
}
