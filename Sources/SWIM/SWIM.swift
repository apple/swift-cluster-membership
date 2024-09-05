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

/// ## Scalable Weakly-consistent Infection-style Process Group Membership Protocol
///
/// > As you swim lazily through the milieu, <br/>
/// > The secrets of the world will infect you.
///
/// Implementation of the SWIM protocol in abstract terms, not dependent on any specific runtime.
/// The actual implementation resides in `SWIM.Instance`.
///
/// ### Terminology
/// This implementation follows the original terminology mostly directly, with the notable exception of the original
/// wording of "confirm" being rather represented as `SWIM.Status.dead`, as we found the "confirm" wording to be
/// confusing in practice.
///
/// ### Extensions & Modifications
///
/// This implementation has a few notable extensions and modifications implemented, some documented already in the initial
/// SWIM paper, some in the Lifeguard extensions paper and some being simple adjustments we found practical in our environments.
///
/// - The "random peer selection" is not completely ad-hoc random, but follows a _stable order_, randomized on peer insertion.
///   - Unlike the completely random selection in the original paper. This has the benefit of consistently going "around"
///     all peers participating in the cluster, enabling a more efficient spread of membership information among peers,
///     by allowing us to avoid continuously (yet randomly) selecting the same few peers.
///   - This optimization is described in the original SWIM paper, and followed by some implementations.
///
/// - Introduction of an `.unreachable` status, that is ordered after `.suspect` and before `.dead`.
///   - This is because the decision to move an unreachable peer to .dead status is a large and important decision,
///     in which user code may want to participate, e.g. by attempting "shoot the other peer in the head" or other patterns,
///     before triggering the `.dead` status (which usually implies a complete removal of information of that peer existence from the cluster),
///     after which no further communication with given peer will ever be possible anymore.
///   - The `.unreachable` status is optional and _disabled_ by default.
///   - Other SWIM implementations handle this problem by _storing_ dead members for a period of time after declaring them dead,
///     also deviating from the original paper; so we conclude that this use case is quite common and allow addressing it in various ways.
///
/// - Preservation of `.unreachable` information
///   - The original paper does not keep in memory information about dead peers,
///     it only gossips the information that a member is now dead, but does not keep tombstones for later reference.
///
/// Implementations of extensions documented in the Lifeguard paper (linked below):
///
/// - Local Health Aware Probe - which replaces the static timeouts in probing with a dynamic one, taking into account
///   recent communication failures of our member with others.
/// - Local Health Aware Suspicion - which improves the way `.suspect` states and their timeouts are handled,
///   effectively relying on more information about unreachability. See: `suspicionTimeout`.
/// - Buddy System - enables members to directly and immediately notify suspect peers about them being suspected,
///   such that they have more time and a chance to refute these suspicions more quickly, rather than relying on completely
///   random gossip for that suspicion information to reach such suspect peer.
///
/// SWIM serves as a low-level distributed failure detector mechanism.
/// It also maintains its own membership in order to monitor and select peers to ping with periodic health checks,
/// however this membership is not directly the same as the high-level membership exposed by the `Cluster`.
///
/// ### SWIM Membership
/// SWIM provides a weakly consistent view on the process group membership.
/// Membership in this context means that we have some knowledge about the node, that was acquired by either
/// communicating with the peer directly, for example when initially connecting to the cluster,
/// or because some other peer shared information about it with us.
/// To avoid moving a peer "back" into alive or suspect state because of older statuses that get replicated,
/// we need to be able to put them into temporal order. For this reason each peer has an incarnation number assigned to it.
///
/// This number is monotonically increasing and can only be incremented by the respective peer itself and only if it is
/// suspected by another peer in its current incarnation.
///
/// The ordering of statuses is as follows:
///
///     alive(N) < suspect(N) < alive(N+1) < suspect(N+1) < dead
///
/// A member that has been declared dead can *never* return from that status and has to be restarted to join the cluster.
/// Note that such "restarted node" from SWIM's perspective is simply a new node which happens to occupy the same host/port,
/// as nodes are identified by their unique identifiers (`ClusterMembership.Node.uid`).
///
/// The information about dead nodes will be kept for a configurable amount of time, after which it will be removed to
/// prevent the state on each node from growing too big. The timeout value should be chosen to be big enough to prevent
/// faulty nodes from re-joining the cluster and is usually in the order of a few days.
///
/// ### SWIM Gossip
///
/// SWIM uses an infection style gossip mechanism to replicate state across the cluster.
/// The gossip payload contains information about other node’s observed status, and will be disseminated throughout the
/// cluster by piggybacking onto periodic health check messages, i.e. whenever a node is sending a ping, a ping request,
/// or is responding with an acknowledgement, it will include the latest gossip with that message as well. When a node
/// receives gossip, it has to apply the statuses to its local state according to the ordering stated above. If a node
/// receives gossip about itself, it has to react accordingly.
///
/// If it is suspected by another peer in its current incarnation, it has to increment its incarnation in response.
/// If it has been marked as dead, it SHOULD shut itself down (i.e. terminate the entire node / service), to avoid "zombie"
/// nodes staying around even though they are already ejected from the cluster.
///
/// ### SWIM Protocol Logic Implementation
///
/// See `SWIM.Instance` for a detailed discussion on the implementation.
///
/// ### Further Reading
///
/// - [SWIM: Scalable Weakly-consistent Infection-style Process Group Membership Protocol](https://www.cs.cornell.edu/projects/Quicksilver/public_pdfs/SWIM.pdf)
/// - [Lifeguard: Local Health Awareness for More Accurate Failure Detection](https://arxiv.org/abs/1707.00788)
public enum SWIM {}

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
    public enum PingResponse<Peer: SWIMPeer, PingRequestOrigin: SWIMPingRequestOriginPeer>: Codable, Sendable {
        /// - parameters:
        ///   - target: the target of the ping;
        ///     On the remote "pinged" node which is about to send an ack back to the ping origin this should be filled with the `myself` peer.
        ///   - incarnation: the incarnation of the peer sent in the `target` field
        ///   - payload: additional gossip data to be carried with the message.
        ///   - sequenceNumber: the `sequenceNumber` of the `ping` message this ack is a "reply" for;
        ///     It is used on the ping origin to co-relate the reply with its handling code.
        case ack(target: Peer, incarnation: Incarnation, payload: GossipPayload<Peer>?, sequenceNumber: SWIM.SequenceNumber)

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
    public struct GossipPayload<Peer: SWIMPeer>: Codable, Sendable {
        /// Explicit case to signal "no gossip payload"
        ///
        /// Gossip information about a few select members.
        public let members: [SWIM.Member<Peer>]
        
        public init(members: [SWIM.Member<Peer>]) {
            self.members = members
        }
    }
}
