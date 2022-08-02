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

extension SWIM {
    /// Incarnation numbers serve as sequence number and used to determine which observation
    /// is "more recent" when comparing gossiped information.
    public typealias Incarnation = UInt64

    /// A sequence number which can be used to associate with messages in order to establish an request/response
    /// relationship between ping/pingRequest and their corresponding ack/nack messages.
    public typealias SequenceNumber = UInt32

    /// Typealias for the underlying membership representation.
    public typealias Membership<Peer: SWIMPeer> = Dictionary<Node, SWIM.Member<Peer>>.Values
}

extension SWIM {
    /// Message sent in reply to a `.ping`.
    ///
    /// The ack may be delivered directly in a request-response fashion between the probing and pinged members,
    /// or indirectly, as a result of a `pingRequest` message.
    public enum PingResponse<Peer: SWIMPeer, PingRequestOrigin: SWIMPingRequestOriginPeer>: Sendable {
        /// - parameters:
        ///   - target: the target of the ping;
        ///     On the remote "pinged" node which is about to send an ack back to the ping origin this should be filled with the `myself` peer.
        ///   - incarnation: the incarnation of the peer sent in the `target` field
        ///   - payload: additional gossip data to be carried with the message.
        ///   - sequenceNumber: the `sequenceNumber` of the `ping` message this ack is a "reply" for;
        ///     It is used on the ping origin to co-relate the reply with its handling code.
        case ack(target: Peer, incarnation: Incarnation, payload: GossipPayload<Peer>, sequenceNumber: SWIM.SequenceNumber)

        /// A `.nack` MAY ONLY be sent by an *intermediary* member which was received a `pingRequest` to perform a `ping` of some `target` member.
        /// It SHOULD NOT be sent by a peer that received a `.ping` directly.
        ///
        /// The nack allows the origin of the ping request to know if the `k` peers it asked to perform the indirect probes,
        /// are still responsive to it, or if perhaps that communication by itself is also breaking down. This information is
        /// used to adjust the `localHealthMultiplier`, which impacts probe and timeout intervals.
        ///
        /// Note that nack information DOES NOT directly cause unreachability or suspicions, it only adjusts the timeouts
        /// and intervals used by the swim instance in order to take into account the potential that our local node is
        /// potentially not healthy.
        ///
        /// - parameters:
        ///   - target: the target of the ping;
        ///     On the remote "pinged" node which is about to send an ack back to the ping origin this should be filled with the `myself` peer.
        ///   - target: the target of the ping;
        ///     On the remote "pinged" node which is about to send an ack back to the ping origin this should be filled with the `myself` peer.
        ///   - payload: The gossip payload to be carried in this message.
        ///
        /// - SeeAlso: Lifeguard IV.A. Local Health Aware Probe
        case nack(target: Peer, sequenceNumber: SWIM.SequenceNumber)

        /// This is a "pseudo-message", in the sense that it is not transported over the wire, but should be triggered
        /// and fired into an implementation Shell when a ping has timed out.
        ///
        /// If a response for some reason produces a different error immediately rather than through a timeout,
        /// the shell should also emit a `.timeout` response and feed it into the `SWIM.Instance` as it is important for
        /// timeout adjustments that the instance makes. The instance does not need to know specifics about the reason of
        /// a response not arriving, thus they are all handled via the same timeout response rather than extra "error" responses.
        ///
        /// - parameters:
        ///   - target: the target of the ping;
        ///     On the remote "pinged" node which is about to send an ack back to the ping origin this should be filled with the `myself` peer.
        ///   - pingRequestOrigin: if this response/timeout is in response to a ping that was caused by a pingRequest,
        ///     `pingRequestOrigin` must contain the original peer which originated the ping request.
        ///   - timeout: the timeout interval value that caused this message to be triggered;
        ///     In case of "cancelled" operations or similar semantics it is allowed to use a placeholder value here.
        ///   - sequenceNumber: the `sequenceNumber` of the `ping` message this ack is a "reply" for;
        ///     It is used on the ping origin to co-relate the reply with its handling code.
        case timeout(target: Peer, pingRequestOrigin: PingRequestOrigin?, timeout: Duration, sequenceNumber: SWIM.SequenceNumber)

        /// Sequence number of the initial request this is a response to.
        /// Used to pair up responses to the requests which initially caused them.
        ///
        /// All ping responses are guaranteed to have a sequence number attached to them.
        public var sequenceNumber: SWIM.SequenceNumber {
            switch self {
            case .ack(_, _, _, let sequenceNumber):
                return sequenceNumber
            case .nack(_, let sequenceNumber):
                return sequenceNumber
            case .timeout(_, _, _, let sequenceNumber):
                return sequenceNumber
            }
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Gossip

extension SWIM {
    /// A piece of "gossip" about a specific member of the cluster.
    ///
    /// A gossip will only be spread a limited number of times, as configured by `settings.gossip.gossipedEnoughTimes(_:members:)`.
    public struct Gossip<Peer: SWIMPeer>: Equatable {
        /// The specific member (including status) that this gossip is about.
        ///
        /// A change in member status implies a new gossip must be created and the count for the rumor mongering must be reset.
        public let member: SWIM.Member<Peer>
        /// The number of times this specific gossip message was gossiped to another peer.
        public internal(set) var numberOfTimesGossiped: Int
    }

    /// A `GossipPayload` is used to spread gossips about members.
    public enum GossipPayload<Peer: SWIMPeer>: Sendable {
        /// Explicit case to signal "no gossip payload"
        ///
        /// Effectively equivalent to an empty `.membership([])` case.
        case none
        /// Gossip information about a few select members.
        case membership([SWIM.Member<Peer>])
    }
}

extension SWIM.GossipPayload {
    /// True if the underlying gossip is empty.
    public var isNone: Bool {
        switch self {
        case .none:
            return true
        case .membership:
            return false
        }
    }

    /// True if the underlying gossip contains membership information.
    public var isMembership: Bool {
        switch self {
        case .none:
            return false
        case .membership:
            return true
        }
    }
}
