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
import struct Dispatch.DispatchTime
import enum Dispatch.DispatchTimeInterval

/// Any peer in the cluster, can be used used to identify a peer using its unique node that it represents.
public protocol SWIMAddressablePeer {
    /// Node that this peer is representing.
    var node: ClusterMembership.Node { get }
}

/// SWIM peer which is the origin of a `.ping`.
/// It represents a peer that should only be "replied" to.
public protocol SWIMPingOriginPeer: SWIMAddressablePeer {
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

/// SWIM peer which can be initiated contact with, by sending ping or ping request messages.
public protocol SWIMPeer: SWIMAddressablePeer {
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
        timeout: DispatchTimeInterval,
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
        timeout: DispatchTimeInterval,
        sequenceNumber: SWIM.SequenceNumber,
        onComplete: @escaping (Result<SWIM.PingResponse, Error>) -> Void
    )
}
