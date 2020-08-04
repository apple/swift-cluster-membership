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

extension SWIM {
    public typealias Peer = SWIMPeerProtocol
    public typealias AnyPeer = AnySWIMPeer
}

public protocol SWIMAddressablePeer {
    /// Node that this peer is representing.
    var node: ClusterMembership.Node { get set }
}

extension ClusterMembership.Node: SWIMAddressablePeer {
    public var node: ClusterMembership.Node {
        get {
            self
        }
        set {
            self = newValue
        }
    }
}

public protocol SWIMPeerReplyProtocol: SWIMAddressablePeer {
    /// Acknowledge a ping.
    func ack(
        acknowledging: SWIM.SequenceNumber,
        target: SWIMAddressablePeer,
        incarnation: SWIM.Incarnation,
        payload: SWIM.GossipPayload
    )

    /// "NegativeAcknowledge" a ping.
    func nack(
        acknowledging: SWIM.SequenceNumber,
        target: SWIMAddressablePeer
    )
}

public protocol SWIMPeerProtocol: SWIMPeerReplyProtocol {
    /// "Ping" another SWIM peer.
    ///
    /// - Parameters:
    ///   - payload:
    ///   - origin:
    ///   - timeout:
    ///   - onComplete:
    func ping(
        payload: SWIM.GossipPayload,
        from origin: SWIMAddressablePeer,
        timeout: SWIMTimeAmount,
        sequenceNumber: SWIM.SequenceNumber,
        onComplete: @escaping (Result<SWIM.PingResponse, Error>) -> Void
    )

    /// "Ping Request" a SWIM peer.
    ///
    /// - Parameters:
    ///   - target:
    ///   - payload:
    ///   - origin:
    ///   - timeout: timeout during which we expect the other peer to have replied to us with a PingResponse about the pinged node.
    ///     If we get no response about that peer in that time, this `pingReq` is considered failed.
    ///   - onComplete: must be invoked when the a corresponding reply (ack, nack) or timeout event for this ping request occurs.
    ///     It may be necessary to generate and pass a `SWIM.SequenceNumber` when sending the request, such that the replies can be correlated to this request and completion block.
    func pingRequest(
        target: SWIMAddressablePeer,
        payload: SWIM.GossipPayload,
        from origin: SWIMAddressablePeer,
        timeout: SWIMTimeAmount,
        sequenceNumber: SWIM.SequenceNumber,
        onComplete: @escaping (Result<SWIM.PingResponse, Error>) -> Void
    )

    /// Type erase this member into an `AnySWIMMember`
    var asAnyPeer: AnySWIMPeer { get }
}

extension SWIMPeerProtocol {
    public var asAnyPeer: AnySWIMPeer {
        .init(peer: self)
    }
}

public struct AnySWIMPeer: Hashable, SWIMPeerProtocol {
    var peer: SWIMPeerProtocol

    public init(peer: SWIMPeerProtocol) {
        self.peer = peer
    }

    public var node: ClusterMembership.Node {
        get {
            self.peer.node
        }
        set {
            self.peer.node = newValue
        }
    }

    public func ping(
        payload: SWIM.GossipPayload,
        from origin: SWIMAddressablePeer,
        timeout: SWIMTimeAmount,
        sequenceNumber: SWIM.SequenceNumber,
        onComplete: @escaping (Result<SWIM.PingResponse, Error>) -> Void
    ) {
        self.peer.ping(payload: payload, from: origin, timeout: timeout, sequenceNumber: sequenceNumber, onComplete: onComplete)
    }

    public func pingRequest(
        target: SWIMAddressablePeer,
        payload: SWIM.GossipPayload,
        from origin: SWIMAddressablePeer,
        timeout: SWIMTimeAmount,
        sequenceNumber: SWIM.SequenceNumber,
        onComplete: @escaping (Result<SWIM.PingResponse, Error>) -> Void
    ) {
        self.peer.pingRequest(target: target, payload: payload, from: origin, timeout: timeout, sequenceNumber: sequenceNumber, onComplete: onComplete)
    }

    public func ack(
        acknowledging: SWIM.SequenceNumber,
        target: SWIMAddressablePeer,
        incarnation: SWIM.Incarnation,
        payload: SWIM.GossipPayload
    ) {
        self.peer.ack(acknowledging: acknowledging, target: target, incarnation: incarnation, payload: payload)
    }

    public func nack(
        acknowledging: SWIM.SequenceNumber,
        target: SWIMAddressablePeer
    ) {
        self.peer.nack(acknowledging: acknowledging, target: target)
    }

    public func hash(into hasher: inout Hasher) {
        self.peer.node.hash(into: &hasher)
    }

    public static func == (lhs: AnySWIMPeer, rhs: AnySWIMPeer) -> Bool {
        lhs.peer.node == rhs.peer.node
    }
}
