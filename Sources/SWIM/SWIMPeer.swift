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
    public typealias Peer = SWIMPeer
}

public protocol AddressableSWIMPeer {
    /// Node that this peer is representing.
    var node: ClusterMembership.Node { get set }
}

extension ClusterMembership.Node: AddressableSWIMPeer {
    public var node: ClusterMembership.Node {
        get {
            self
        }
        set {
            self = newValue
        }
    }
}

public protocol PingOriginSWIMPeer: AddressableSWIMPeer {
    /// Acknowledge a ping.
    func ack(
        acknowledging: SWIM.SequenceNumber,
        target: AddressableSWIMPeer,
        incarnation: SWIM.Incarnation,
        payload: SWIM.GossipPayload
    )

    /// "NegativeAcknowledge" a ping.
    func nack(
        acknowledging: SWIM.SequenceNumber,
        target: AddressableSWIMPeer
    )
}

public protocol SWIMPeer: PingOriginSWIMPeer {
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
        target: AddressableSWIMPeer,
        payload: SWIM.GossipPayload,
        from origin: AddressableSWIMPeer,
        timeout: SWIMTimeAmount,
        sequenceNumber: SWIM.SequenceNumber,
        onComplete: @escaping (Result<SWIM.PingResponse, Error>) -> Void
    )
}
