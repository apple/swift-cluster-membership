//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Cluster Membership open source project
//
// Copyright (c) 2020-2022 Apple Inc. and the Swift Cluster Membership project authors
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

public extension SWIM {
    /// SWIMPeer designed to deliver messages over UDP in collaboration with the SWIMNIOHandler.
    actor NIOPeer: SWIMPeer, SWIMPingOriginPeer, SWIMPingRequestOriginPeer, CustomStringConvertible {
        public let swimNode: ClusterMembership.Node
        internal nonisolated var node: ClusterMembership.Node {
            self.swimNode
        }

        internal let channel: Channel

        public init(node: Node, channel: Channel) {
            self.swimNode = node
            self.channel = channel
        }

        public func ping(
            payload: GossipPayload<SWIM.NIOPeer>,
            from origin: SWIM.NIOPeer,
            timeout: Swift.Duration,
            sequenceNumber: SWIM.SequenceNumber
        ) async throws -> PingResponse<SWIM.NIOPeer, SWIM.NIOPeer> {
            try await withCheckedThrowingContinuation { continuation in
                let message = SWIM.Message.ping(replyTo: origin, payload: payload, sequenceNumber: sequenceNumber)
                let command = SWIMNIOWriteCommand(message: message, to: self.swimNode, replyTimeout: timeout.toNIO, replyCallback: { reply in
                    switch reply {
                    case .success(.response(.nack(_, _))):
                        continuation.resume(throwing: SWIMNIOIllegalMessageTypeError("Unexpected .nack reply to .ping message! Was: \(reply)"))

                    case .success(.response(let pingResponse)):
                        assert(sequenceNumber == pingResponse.sequenceNumber, "callback invoked with not matching sequence number! Submitted with \(sequenceNumber) but invoked with \(pingResponse.sequenceNumber)!")
                        continuation.resume(returning: pingResponse)

                    case .failure(let error):
                        continuation.resume(throwing: error)

                    case .success(let other):
                        continuation.resume(throwing:
                            SWIMNIOIllegalMessageTypeError("Unexpected message, got: [\(other)]:\(reflecting: type(of: other)) while expected \(PingResponse<SWIM.NIOPeer, SWIM.NIOPeer>.self)"))
                    }
                })

                self.channel.writeAndFlush(command, promise: nil)
            }
        }

        public func pingRequest(
            target: SWIM.NIOPeer,
            payload: GossipPayload<SWIM.NIOPeer>,
            from origin: SWIM.NIOPeer,
            timeout: Duration,
            sequenceNumber: SWIM.SequenceNumber
        ) async throws -> PingResponse<SWIM.NIOPeer, SWIM.NIOPeer> {
            try await withCheckedThrowingContinuation { continuation in
                let message = SWIM.Message.pingRequest(target: target, replyTo: origin, payload: payload, sequenceNumber: sequenceNumber)
                let command = SWIMNIOWriteCommand(message: message, to: self.node, replyTimeout: timeout.toNIO, replyCallback: { reply in
                    switch reply {
                    case .success(.response(let pingResponse)):
                        assert(sequenceNumber == pingResponse.sequenceNumber, "callback invoked with not matching sequence number! Submitted with \(sequenceNumber) but invoked with \(pingResponse.sequenceNumber)!")
                        continuation.resume(returning: pingResponse)

                    case .failure(let error):
                        continuation.resume(throwing: error)

                    case .success(let other):
                        continuation.resume(throwing: SWIMNIOIllegalMessageTypeError("Unexpected message, got: \(other) while expected \(PingResponse<SWIM.NIOPeer, SWIM.NIOPeer>.self)"))
                    }
                })

                self.channel.writeAndFlush(command, promise: nil)
            }
        }

        public func ack(
            acknowledging sequenceNumber: SWIM.SequenceNumber,
            target: SWIM.NIOPeer,
            incarnation: Incarnation,
            payload: GossipPayload<SWIM.NIOPeer>
        ) {
            let message = SWIM.Message.response(.ack(target: target, incarnation: incarnation, payload: payload, sequenceNumber: sequenceNumber))
            let command = SWIMNIOWriteCommand(message: message, to: self.node, replyTimeout: .seconds(0), replyCallback: nil)

            self.channel.writeAndFlush(command, promise: nil)
        }

        public func nack(
            acknowledging sequenceNumber: SWIM.SequenceNumber,
            target: SWIM.NIOPeer
        ) {
            let message = SWIM.Message.response(.nack(target: target, sequenceNumber: sequenceNumber))
            let command = SWIMNIOWriteCommand(message: message, to: self.node, replyTimeout: .seconds(0), replyCallback: nil)

            self.channel.writeAndFlush(command, promise: nil)
        }

        public nonisolated var description: String {
            "NIOPeer(\(self.node))"
        }
    }
}

extension SWIM.NIOPeer: Hashable {
    public nonisolated func hash(into hasher: inout Hasher) {
        self.node.hash(into: &hasher)
    }

    public static func == (lhs: SWIM.NIOPeer, rhs: SWIM.NIOPeer) -> Bool {
        lhs.node == rhs.node
    }
}

public struct SWIMNIOTimeoutError: Error, CustomStringConvertible {
    let timeout: Duration
    let message: String

    init(timeout: NIO.TimeAmount, message: String) {
        self.timeout = .nanoseconds(Int(timeout.nanoseconds))
        self.message = message
    }

    init(timeout: Duration, message: String) {
        self.timeout = timeout
        self.message = message
    }

    public var description: String {
        "SWIMNIOTimeoutError(timeout: \(self.timeout.prettyDescription), \(self.message))"
    }
}

public struct SWIMNIOIllegalMessageTypeError: Error, CustomStringConvertible {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    public var description: String {
        "SWIMNIOIllegalMessageTypeError(\(self.message))"
    }
}
