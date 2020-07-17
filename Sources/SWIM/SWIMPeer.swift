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

extension SWIM {
    public typealias Peer = SWIMPeerProtocol
    public typealias AnyPeer = AnySWIMPeer
}

public protocol AddressableSWIMPeer {
    /// Node that this peer is representing.
    var node: ClusterMembership.Node { get }
}

extension ClusterMembership.Node: AddressableSWIMPeer {
    public var node: ClusterMembership.Node {
        self
    }
}

public protocol SWIMPeerReplyProtocol: AddressableSWIMPeer {
    /// Acknowledge a ping.
    func ack(target: AddressableSWIMPeer, incarnation: SWIM.Incarnation, payload: SWIM.GossipPayload)

    /// "NegativeAcknowledge" a ping.
    func nack(target: AddressableSWIMPeer)
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
        from origin: AddressableSWIMPeer,
        timeout: SWIMTimeAmount,
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
    ///   - onComplete:
    func pingReq(
        target: AddressableSWIMPeer,
        payload: SWIM.GossipPayload,
        from origin: AddressableSWIMPeer,
        timeout: SWIMTimeAmount,
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
    let peer: SWIMPeerProtocol

    public init(peer: SWIMPeerProtocol) {
        self.peer = peer
    }

    public var node: ClusterMembership.Node {
        self.peer.node
    }

    public func ping(
        payload: SWIM.GossipPayload,
        from origin: AddressableSWIMPeer,
        timeout: SWIMTimeAmount,
        onComplete: @escaping (Result<SWIM.PingResponse, Error>) -> Void
    ) {
        self.peer.ping(payload: payload, from: origin, timeout: timeout, onComplete: onComplete)
    }

    public func pingReq(
        target: AddressableSWIMPeer,
        payload: SWIM.GossipPayload,
        from origin: AddressableSWIMPeer,
        timeout: SWIMTimeAmount,
        onComplete: @escaping (Result<SWIM.PingResponse, Error>) -> Void
    ) {
        self.peer.pingReq(target: target, payload: payload, from: origin, timeout: timeout, onComplete: onComplete)
    }

    public func ack(target: AddressableSWIMPeer, incarnation: SWIM.Incarnation, payload: SWIM.GossipPayload) {
        self.peer.ack(target: target, incarnation: incarnation, payload: payload)
    }

    public func nack(target: AddressableSWIMPeer) {
        self.peer.nack(target: target)
    }

    public func hash(into hasher: inout Hasher) {
        self.peer.node.hash(into: &hasher)
    }

    public static func == (lhs: AnySWIMPeer, rhs: AnySWIMPeer) -> Bool {
        lhs.peer.node == rhs.peer.node
    }
}
