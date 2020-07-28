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
        public let node: Node

        var channel: Channel?

        /// When sending messages we generate sequence numbers which allow us to match their replies
        /// with corresponding completion handlers
        private let nextSequenceNumber: NIOAtomic<UInt32>

        public init(node: Node, channel: Channel?) {
            self.node = node
            self.nextSequenceNumber = .makeAtomic(value: 0)
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

            let sequenceNr = self.nextSequenceNumber.add(1)
            let message = SWIM.Message.ping(replyTo: nioOrigin, payload: payload, sequenceNr: sequenceNr)

            let command = WriteCommand(message: message, to: self.node, replyTimeout: timeout.toNIO, replyCallback: { reply in
                switch reply {
                case .success(.response(let pingResponse, let gotSequenceNr)):
                    assert(sequenceNr == gotSequenceNr, "callback invoked with not matching sequence number! Submitted with \(sequenceNr) but invoked with \(gotSequenceNr)!")
                    onComplete(.success(pingResponse))
                case .failure(let error):
                    onComplete(.failure(error))

                case .success(let other):
                    fatalError("Unexpected message, got: \(other) while expected \(PingResponse.self)")
                }
            })

            channel.writeAndFlush(command, promise: nil)
        }

        public func pingRequest(
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

            let sequenceNr = self.nextSequenceNumber.add(1)
            let message = SWIM.Message.pingReq(target: nioTarget, replyTo: nioOrigin, payload: payload, sequenceNr: sequenceNr)

            let command = WriteCommand(message: message, to: self.node, replyTimeout: timeout.toNIO, replyCallback: { reply in
                switch reply {
                case .success(.response(let pingResponse, let gotSequenceNr)):
                    assert(sequenceNr == gotSequenceNr, "callback invoked with not matching sequence number! Submitted with \(sequenceNr) but invoked with \(gotSequenceNr)!")
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
            acknowledging: SWIM.SequenceNr,
            target: AddressableSWIMPeer,
            incarnation: Incarnation,
            payload: GossipPayload
        ) {
            guard let channel = self.channel else {
                fatalError("\(#function) failed, channel was not initialized for \(self)!")
            }

            let sequenceNr = acknowledging
            let message = SWIM.Message.response(.ack(target: target.node, incarnation: incarnation, payload: payload), sequenceNr: sequenceNr)
            let command = WriteCommand(message: message, to: self.node, replyTimeout: .seconds(0), replyCallback: nil)

            channel.writeAndFlush(command, promise: nil)
        }

        public func nack(
            acknowledging: SWIM.SequenceNr,
            target: AddressableSWIMPeer
        ) {
            guard let channel = self.channel else {
                fatalError("\(#function) failed, channel was not initialized for \(self)!")
            }

            let sequenceNr = acknowledging
            let message = SWIM.Message.response(.nack(target: target.node), sequenceNr: sequenceNr)
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

public struct SWIMNIOTimeoutError: Error {
    let timeout: NIO.TimeAmount
    let message: String

    init(timeout: NIO.TimeAmount, message: String) {
        self.timeout = timeout
        self.message = message
    }
}
