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

/// Any peer in the cluster, can be used used to identify a peer using its unique node that it represents.
public protocol SWIMAddressablePeer: Sendable {
    /// Node that this peer is representing.
    nonisolated var swimNode: ClusterMembership.Node { get }
}

extension SWIMAddressablePeer {
    internal var node: ClusterMembership.Node {
        self.swimNode
    }
}

/// SWIM A peer which originated a `ping`, should be replied to with an `ack`.
public protocol SWIMPingOriginPeer: SWIMAddressablePeer {
    associatedtype Peer: SWIMPeer

    /// Acknowledge a `ping`.
    ///
    /// - parameters:
    ///   - sequenceNumber: the sequence number of the incoming ping that this ack should acknowledge
    ///   - target: target peer which received the ping (i.e. "myself" on the recipient of the `ping`).
    ///   - incarnation: incarnation number of the target (myself),
    ///     which is used to clarify which status is the most recent on the recipient of this acknowledgement.
    ///   - payload: additional gossip data to be carried with the message.
    ///     It is already trimmed to be no larger than configured in `SWIM.Settings`.
    func ack(
        acknowledging sequenceNumber: SWIM.SequenceNumber,
        target: Peer,
        incarnation: SWIM.Incarnation,
        payload: SWIM.GossipPayload<Peer>
    ) async throws
}

/// A SWIM peer which originated a `pingRequest` and thus can receive either an `ack` or `nack` from the intermediary.
public protocol SWIMPingRequestOriginPeer: SWIMPingOriginPeer {
    associatedtype NackTarget: SWIMPeer

    /// "Negative acknowledge" a ping.
    ///
    /// This message may ONLY be send in an indirect-ping scenario from the "middle" peer.
    /// Meaning, only a peer which received a `pingRequest` and wants to send the `pingRequestOrigin`
    /// a nack in order for it to be aware that its message did reach this member, even if it never gets an `ack`
    /// through this member, e.g. since the pings `target` node is actually not reachable anymore.
    ///
    /// - parameters:
    ///   - sequenceNumber: the sequence number of the incoming `pingRequest` that this nack is a response to
    ///   - target: the target peer which was attempted to be pinged but we didn't get an ack from it yet and are sending a nack back eagerly
    func nack(
        acknowledging sequenceNumber: SWIM.SequenceNumber,
        target: NackTarget
    ) async throws
}

/// SWIM peer which can be initiated contact with, by sending ping or ping request messages.
public protocol SWIMPeer: SWIMAddressablePeer {
    associatedtype Peer: SWIMPeer
    associatedtype PingOrigin: SWIMPingOriginPeer
    associatedtype PingRequestOrigin: SWIMPingRequestOriginPeer

    /// Perform a probe of this peer by sending a `ping` message.
    ///
    /// We expect the reply to be an `ack`.
    ///
    /// - parameters:
    ///   - payload: additional gossip information to be processed by the recipient
    ///   - origin: the origin peer that has initiated this ping message (i.e. "myself" of the sender)
    ///     replies (`ack`s) from to this ping should be send to this peer
    ///   - timeout: timeout during which we expect the other peer to have replied to us with a `PingResponse` about the pinged node.
    ///     If we get no response about that peer in that time, this `ping` is considered failed, and the onResponse MUST be invoked with a `.timeout`.
    ///
    /// - Returns the corresponding reply (`ack`) or `timeout` event for this ping request occurs.
    ///
    /// - Throws if the ping fails or if the reply is `nack`.
    func ping(
        payload: SWIM.GossipPayload<Peer>,
        from origin: PingOrigin,
        timeout: Duration,
        sequenceNumber: SWIM.SequenceNumber
    ) async throws -> SWIM.PingResponse<Peer, PingRequestOrigin>

    /// Send a ping request to this peer, asking it to perform an "indirect ping" of the target on our behalf.
    ///
    /// Any resulting acknowledgements back to us. If not acknowledgements come back from the target, the intermediary
    /// may send back nack messages, indicating that our connection to the intermediary is intact, however we didn't see
    /// acknowledgements from the target itself.
    ///
    /// - parameters:
    ///   - target: target peer that should be probed by this the recipient on our behalf
    ///   - payload: additional gossip information to be processed by the recipient
    ///   - origin: the origin peer that has initiated this `pingRequest` (i.e. "myself" on the sender);
    ///     replies (`ack`s) from this indirect ping should be forwarded to it.
    ///   - timeout: timeout during which we expect the other peer to have replied to us with a `PingResponse` about the pinged node.
    ///     If we get no response about that peer in that time, this `pingRequest` is considered failed, and the onResponse MUST be invoked with a `.timeout`.
    ///
    /// - Returns the corresponding reply (`ack`, `nack`) or `timeout` event for this ping request occurs.
    /// - Throws if the ping request fails
    func pingRequest(
        target: Peer,
        payload: SWIM.GossipPayload<Peer>,
        from origin: PingOrigin,
        timeout: Duration,
        sequenceNumber: SWIM.SequenceNumber
    ) async throws -> SWIM.PingResponse<Peer, PingRequestOrigin>
}
